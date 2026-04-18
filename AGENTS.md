# Repository Guidelines

## Project Structure & Module Organization

`app.py` contains the Flask application, Easy Auth principal parsing, SQL access, and route handlers. Server-rendered UI lives in `templates/`, with the dashboard in `templates/dashboard.html`. Unit tests live in `tests/` and currently center on `tests/test_app.py`. Deployment and verification scripts are in `scripts/`, while Azure infrastructure code is under `infra/terraform/`. Treat `docs/spec.md` as the implementation contract when behavior is unclear.

## Build, Test, and Development Commands

Set up a local environment with `python3 -m venv .venv` and `.venv/bin/pip install -r requirements.txt`. Run the test suite with `.venv/bin/python -m unittest discover -s tests -v`. Start the app locally with `FLASK_SECRET_KEY=dev .venv/bin/flask --app app run --debug`; outside App Service, Easy Auth headers are not trusted by default, so local auth flows are limited. Use `./scripts/deploy_azure.sh` for full Azure provisioning and ZIP deploy, `./scripts/deploy_app_only.sh` to push only the app package, and `terraform init && terraform apply` from `infra/terraform/` for infrastructure-only changes.

## Coding Style & Naming Conventions

Follow existing Python style: 4-space indentation, `snake_case` for functions and variables, `UPPER_SNAKE_CASE` for constants, and small helper functions over deeply nested route logic. Keep Flask templates simple and server-rendered. Shell environment variables in `scripts/` stay uppercase. Terraform inputs and outputs use lowercase snake case. No formatter or linter is configured in the repo, so match the surrounding style and keep imports/order tidy.

## Testing Guidelines

Use `unittest` with test files named `test_*.py` and descriptive `unittest.TestCase` classes such as `AppRouteTests`. Add or update tests for any auth, SQL, or route behavior change. Prefer mocking external dependencies (`pyodbc`, Azure identity, request headers) so tests stay fast and offline. Cover both user and daemon/API flows when touching authentication logic.

## Commit & Pull Request Guidelines

Recent history follows Conventional Commit prefixes like `feat:` and `fix:`; keep subjects short and imperative, for example `fix: handle missing app role`. Pull requests should describe the behavior change, note any Azure or SQL impact, list verification steps, and link the relevant issue if one exists. Include screenshots only for dashboard/template changes.

## Security & Configuration Tips

Never commit `scripts/deploy.env`, `.env*`, or Terraform state files. Keep secrets in environment variables or local-only files derived from `scripts/deploy.env.example`. When changing deployment logic, document any new required app settings or post-provision SQL steps in `README.md` or `infra/terraform/README.md`.

## Functional Requirements Reference

Use `docs/spec.md` to track functional requirements and expected behavior before changing auth, dashboard, API, or infrastructure flows. If implementation details drift from the spec, update the code and the spec together so the repository keeps a single source of truth for required behavior.
