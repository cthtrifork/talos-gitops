"""Run with Python, PyYAML, redpanda-connect and promtool on PATH."""
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest
from urllib.error import URLError
from urllib.parse import parse_qs, urlsplit
from urllib.request import urlopen

import yaml

ROOT = Path(__file__).resolve().parents[3]
COCKPIT = ROOT / "k8s/apps/claude-system/cockpit"
MONITORING = ROOT / "k8s/infra/kube-prometheus-stack"


class HardwareTemperaturesTest(unittest.TestCase):
    def test_status_query_and_alerts(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            query = self.check_connect(work)
            self.check_prometheus(work, query)

    def check_connect(self, work):
        queries = []
        fail_query = False

        class Prometheus(BaseHTTPRequestHandler):
            def do_GET(self):
                queries.append(parse_qs(urlsplit(self.path).query)["query"][0])
                self.send_response(503 if fail_query else 200)
                self.end_headers()
                samples = [
                    ({"node": "talos-one"}, "1"),
                    ({"node": "talos-two"}, "1"),
                    ({"node": "talos-one", "chip_name": "coretemp", "stat": "min"}, "0"),
                ]
                self.wfile.write(json.dumps({
                    "status": "success",
                    "data": {"result": [{"metric": labels, "value": [0, value]} for labels, value in samples]},
                }).encode())

            def log_message(self, *_args):
                pass

        conf = yaml.safe_load((COCKPIT / "redpanda-connect.yaml").read_text())
        resources = {resource["label"]: resource for resource in conf["processor_resources"]}
        status = resources["status"]
        workflow = status["processors"][1]["workflow"]
        workflow["branches"] = {"hardware_temperatures": workflow["branches"]["hardware_temperatures"]}
        ui = conf["input"]["broker"]["inputs"][0]
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        ui["http_server"]["address"] = f"127.0.0.1:{port}"
        config = work / "connect.yaml"
        with ThreadingHTTPServer(("127.0.0.1", 0), Prometheus) as prometheus:
            threading.Thread(target=prometheus.serve_forever, daemon=True).start()
            prom = resources["prom_get"]
            prom["http"]["url"] = prom["http"]["url"].replace(
                "${PROM_URL:http://kube-prom-prometheus.kube-prometheus-stack-system.svc:9090}",
                f"http://127.0.0.1:{prometheus.server_port}",
            )
            prom["http"]["retries"] = 0
            config.write_text(yaml.safe_dump({
                "http": {"enabled": False},
                "input": ui,
                "pipeline": {"processors": [{"resource": "status"}]},
                "output": {"sync_response": {}},
                "processor_resources": [status, prom],
            }))
            with subprocess.Popen(["redpanda-connect", "run", str(config)]) as connect:
                try:
                    endpoint = f"http://127.0.0.1:{port}/api/v1/status"

                    def request(parameter=""):
                        with urlopen(endpoint + parameter, timeout=15) as response:
                            return json.load(response)

                    for attempt in range(50):
                        try:
                            default = request()
                            break
                        except URLError:
                            if attempt == 49 or connect.poll() is not None:
                                raise
                            time.sleep(0.1)
                    self.assertEqual(default["hardware_window"], "24h")
                    self.assertEqual(default["hardware_temperatures"], [
                        {"node": "talos-one", "sensors": [{"component": "coretemp", "stat": "min", "value": 0}]},
                        {"node": "talos-two", "sensors": []},
                    ])
                    default_query = queries[-1]
                    for parameter, window in [("24h", "24h"), ("7d", "7d"), ("30d", "30d"), ("1m%5D", "24h")]:
                        self.assertEqual(request("?hardware=" + parameter)["hardware_window"], window)
                        self.assertIn(f"min_over_time(node_hwmon_temp_celsius[{window}])", queries[-1])
                        self.assertIn(f"max_over_time(node_hwmon_temp_celsius[{window}])", queries[-1])
                    fail_query = True
                    failed = request()
                    self.assertNotIn("hardware_temperatures", failed)
                    self.assertIn("hardware_temperatures", failed["meta"]["workflow"]["failed"])
                finally:
                    connect.terminate()
                    prometheus.shutdown()
        return default_query

    def check_prometheus(self, work, query):
        rule = yaml.safe_load((MONITORING / "prometheusrule-hardware.yaml").read_text())
        selector = yaml.safe_load(
            (MONITORING / "rendered/kube-prometheus-stack/prometheus/prometheus.yaml").read_text()
        )["spec"]
        self.assertEqual(selector["ruleNamespaceSelector"], {})
        for key, value in selector["ruleSelector"]["matchLabels"].items():
            self.assertEqual(rule["metadata"]["labels"][key], value)
        (work / "rules.yaml").write_text(yaml.safe_dump(rule["spec"]))

        instance = "10.0.0.10:9100"
        series = [
            {"series": 'kube_node_info{node="talos-one", internal_ip="10.0.0.10"}', "values": "1+0x20"},
            {"series": 'kube_node_info{node="talos-two", internal_ip="10.0.0.11"}', "values": "1+0x20"},
        ]
        for chip, name, temperatures in [
            ("platform_coretemp_0", "coretemp", ["0+0x10 55+0x9", "60+0x10 54+0x9"]),
            ("pci_0100", "nvme", ["76+0x20"]),
            ("pci_0200", "nvme", ["12+0x4 stale"]),
            ("acpi", "acpitz", ["-263+0x20"]),
        ]:
            labels = f'instance="{instance}",chip="{chip}"'
            series.append({"series": f'node_hwmon_chip_names{{{labels},chip_name="{name}"}}', "values": "1+0x20"})
            for sensor, values in enumerate(temperatures, 1):
                series.append({"series": f'node_hwmon_temp_celsius{{{labels},sensor="temp{sensor}"}}', "values": values})

        expected = [
            {"labels": f'{{node="talos-{node}"}}', "value": 1} for node in ("one", "two")
        ]
        for driver, values in [("coretemp", [55, 0, 60, 21 / 1440]), ("nvme", [76, 12, 76, 5 / 1440])]:
            for stat, value in zip(("current", "min", "max", "coverage"), values):
                labels = f'{{instance="{instance}",node="talos-one",chip_name="{driver}",stat="{stat}"}}'
                expected.append({"labels": labels, "value": value})

        def alert(name, severity, summary, description, **labels):
            return {
                "alertname": name,
                "exp_alerts": [{
                    "exp_labels": {"instance": instance, "node": "talos-one", "severity": severity, **labels},
                    "exp_annotations": {"summary": summary, "description": description},
                }],
            }

        suite = {
            "rule_files": ["rules.yaml"],
            "evaluation_interval": "1m",
            "tests": [{
                "interval": "1m",
                "input_series": series,
                "promql_expr_test": [{"expr": query, "eval_time": "20m", "exp_samples": expected}],
                "alert_rule_test": [
                    {"alertname": "NodeNVMeTemperatureCritical", "eval_time": "1m", "exp_alerts": []},
                    {"alertname": "NodeNVMeTemperatureHigh", "eval_time": "4m", "exp_alerts": []},
                    {"alertname": "NodeHardwareTemperatureLow", "eval_time": "9m", "exp_alerts": []},
                    {"eval_time": "2m", **alert("NodeNVMeTemperatureCritical", "critical",
                                                "Critical NVMe temperature on talos-one", "NVMe temperature is 76.0°C.")},
                    {"eval_time": "5m", **alert("NodeNVMeTemperatureHigh", "warning",
                                                "High NVMe temperature on talos-one", "NVMe temperature is 76.0°C.")},
                    {"eval_time": "10m", **alert("NodeHardwareTemperatureLow", "warning",
                                                 "Low coretemp temperature on talos-one", "coretemp temperature is 0.0°C.",
                                                 chip_name="coretemp")},
                    {"alertname": "NodeHardwareTemperatureLow", "eval_time": "20m", "exp_alerts": []},
                ],
            }],
        }
        (work / "test.yaml").write_text(yaml.safe_dump(suite))
        subprocess.run(["promtool", "check", "rules", "rules.yaml"], cwd=work, check=True)
        subprocess.run(["promtool", "test", "rules", "test.yaml"], cwd=work, check=True)


if __name__ == "__main__":
    unittest.main()
