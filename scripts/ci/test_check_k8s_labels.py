#!/usr/bin/env python3
"""Test suite for check-k8s-labels.py"""
import sys
import tempfile
from pathlib import Path
import subprocess

def test_valid_labels():
    """Test that valid labels pass validation."""
    yaml_content = """
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  labels:
    app: my-app
    version: "1.0.0"
    env: prod
    app.kubernetes.io/name: test
    app.kubernetes.io/version: "1.0.0"
"""
    with tempfile.TemporaryDirectory() as tmpdir:
        yaml_file = Path(tmpdir) / "test.yaml"
        yaml_file.write_text(yaml_content)
        result = subprocess.run(
            ["python3", "scripts/ci/check-k8s-labels.py", tmpdir],
            cwd="/var/home/caspertdk/projects/private/talos-gitops"
        )
        assert result.returncode == 0, "Valid labels should pass"
        print("✓ test_valid_labels passed")


def test_invalid_plus_in_label():
    """Test that labels with '+' character fail validation."""
    yaml_content = """
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  labels:
    app.kubernetes.io/version: "1.0.0+abc123"
"""
    with tempfile.TemporaryDirectory() as tmpdir:
        yaml_file = Path(tmpdir) / "test.yaml"
        yaml_file.write_text(yaml_content)
        result = subprocess.run(
            ["python3", "scripts/ci/check-k8s-labels.py", tmpdir],
            cwd="/var/home/caspertdk/projects/private/talos-gitops",
            capture_output=True,
            text=True
        )
        assert result.returncode != 0, "Invalid labels with '+' should fail"
        assert "invalid label value" in result.stderr.lower(), "Should report invalid label"
        print("✓ test_invalid_plus_in_label passed")


def test_invalid_space_in_label():
    """Test that labels with spaces fail validation."""
    yaml_content = """
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  labels:
    app: "my app"
"""
    with tempfile.TemporaryDirectory() as tmpdir:
        yaml_file = Path(tmpdir) / "test.yaml"
        yaml_file.write_text(yaml_content)
        result = subprocess.run(
            ["python3", "scripts/ci/check-k8s-labels.py", tmpdir],
            cwd="/var/home/caspertdk/projects/private/talos-gitops",
            capture_output=True,
            text=True
        )
        assert result.returncode != 0, "Invalid labels with spaces should fail"
        print("✓ test_invalid_space_in_label passed")


def test_empty_label_value():
    """Test that empty label values are allowed."""
    yaml_content = """
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  labels:
    app: ""
"""
    with tempfile.TemporaryDirectory() as tmpdir:
        yaml_file = Path(tmpdir) / "test.yaml"
        yaml_file.write_text(yaml_content)
        result = subprocess.run(
            ["python3", "scripts/ci/check-k8s-labels.py", tmpdir],
            cwd="/var/home/caspertdk/projects/private/talos-gitops"
        )
        assert result.returncode == 0, "Empty label values should pass"
        print("✓ test_empty_label_value passed")


if __name__ == "__main__":
    try:
        test_valid_labels()
        test_invalid_plus_in_label()
        test_invalid_space_in_label()
        test_empty_label_value()
        print("\n✓ All tests passed!")
        sys.exit(0)
    except AssertionError as e:
        print(f"\n✗ Test failed: {e}", file=sys.stderr)
        sys.exit(1)
