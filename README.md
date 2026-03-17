# MSBuild Performance Dashboard

Historical build and evaluation time measurements for MSBuild, visualized as an interactive dashboard.

**🌐 Live dashboard:** <https://ar-may.github.io/measurements-msbuild/>

## Features

- **Overview** — trend charts for build time and evaluation time across dates, with branch selector, multi-test selection, and search filtering
- **Comparison** — side-by-side comparison of two snapshots (branch + build ID) with grouped bar chart and delta table showing regressions/improvements
- Supports multiple branches (`main`, `perf_*`) and multiple builds per day
- Automatically excludes failed builds (non-zero exit code)

## Run Locally

1. **Generate `data.json`** from the raw data files:

   ```powershell
   ./build-dashboard.ps1
   ```

2. **Start a local web server** (the dashboard fetches `data.json` via HTTP, so a file server is required):

   ```powershell
   python -m http.server 8080
   ```

3. Open **http://localhost:8080** in your browser.

## Data Structure

Performance data is organized under `data/`:

```
data/
  {branch}/
    {YYYYMMDD.N}/
      PERFLIN/
        {test-name}.json
      PERFWIN/
        {test-name}.json
```

- **Branch** — `main` or feature branch names (e.g. `perf_parallel-eval`)
- **Build ID** — `YYYYMMDD.N` (date + sequence number)
- **Machine** — `PERFLIN` (Linux) or `PERFWIN` (Windows)
- Each JSON contains Crank benchmark results; `build-time` and `evaluation-time` are extracted by the dashboard

## Fetching New Data

```powershell
# Download artifacts from the MSBuild perf pipeline (requires az CLI login)
./fetch-perf-data.ps1

# For a specific branch
./fetch-branch-perf-data.ps1 -BranchName "perf_my-branch"
```

## Deployment

The dashboard auto-deploys to GitHub Pages via the `.github/workflows/dashboard.yml` workflow, which triggers on pushes to `main` that modify `data/**`, `build-dashboard.ps1`, or `index.html`. It can also be triggered manually via workflow dispatch.
