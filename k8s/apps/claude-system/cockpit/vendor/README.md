# Vendored libraries for the cockpit page

`index.html` is a single page with no build step, so its two libraries are checked in as files. `redpanda-connect.yaml` serves exactly these
two paths (`/vendor/htm-preact.js`, `/vendor/croner.js`) and `../kustomization.yaml` puts them in the same ConfigMap as `index.html`.
Renovate does not track them: update them by hand.

| File | Package | Version | Licence | Source file in the npm package |
|---|---|---|---|---|
| `htm-preact.js` | [htm](https://github.com/developit/htm) (bundles Preact 10) | 3.1.1 | Apache-2.0 (htm), MIT (Preact) | `preact/standalone.module.js` |
| `croner.js` | [croner](https://github.com/Hexagon/croner) | 11.0.1 | MIT | `dist/croner.js` |

To refresh one, in an empty scratch directory:

```sh
npm pack htm@<version> croner@<version>
tar xzf htm-<version>.tgz && cp package/preact/standalone.module.js <repo>/k8s/apps/claude-system/cockpit/vendor/htm-preact.js
tar xzf croner-<version>.tgz && cp package/dist/croner.js <repo>/k8s/apps/claude-system/cockpit/vendor/croner.js
```

Then update the table, and check the Renovate runs panel in a browser (the page must be served over HTTP: modules do not load from `file://`).

Only the Renovate runs panel uses htm and Preact so far; the other panels still build their DOM with the `el()` helpers in `index.html`. Croner
is used with `timezone: "UTC"` because the operator reads the cron schedule as UTC.
