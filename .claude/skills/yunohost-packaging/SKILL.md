---
name: yunohost-packaging
description: Use whenever packaging, debugging, upgrading, or reviewing a YunoHost app (repos named *_ynh, manifest.toml, scripts/install|upgrade|remove|backup|restore|change_url|config, config_panel.toml, resources.*, ynh_* helpers, packaging_format 2 / helpers 2.1, package_linter, package_check, systemd/nginx/php-fpm integration for a YunoHost app, SSOwat/SSO integration). Encodes conventions from the official example_ynh template plus concrete bugs already hit and fixed across this account's app packages, so the same root causes aren't re-discovered from scratch every session.
---

# YunoHost app packaging

This skill exists because the same handful of mistakes keep costing a full debug cycle across different app packages. Read the "Hard-won lessons" section before writing install/upgrade/systemd/config_panel logic — most of it is cheaper to apply up front than to discover via a failed install on a live server.

Current baseline across these repos: `packaging_format = 2`, `helpers_version = "2.1"`, targeting YunoHost 12 / Debian Trixie. Treat `example_ynh`'s `manifest.toml` and `scripts/*` as the canonical, up-to-date reference — it is the official YunoHost template and gets patched by upstream maintainers when helper conventions change. When in doubt about current helper syntax, read the actual scripts in this repo rather than relying on training-data memory of older helper versions (v1.x/2.0 syntax differs and will look plausible but be wrong).

## manifest.toml v2 shape

```toml
#:schema https://raw.githubusercontent.com/YunoHost/apps/main/schemas/manifest.v2.schema.json
packaging_format = 2
id = "myapp"
name = "..."
description.en = "..."
version = "1.2.3~ynh1"          # upstream_version~ynhN
maintainers = ["githubuser"]

[upstream]
license = "..."                 # only mandatory upstream.* key; use an SPDX identifier
website / demo / admindoc / userdoc / code = "..."

[integration]
yunohost = ">= 12.1.17"
helpers_version = "2.1"
architectures = "all"
multi_instance = true
ldap = true|false|"not_relevant"   # can a user log in with YunoHost creds
sso = true|false|"not_relevant"    # is the user auto-logged-in via the portal
disk = "50M"
ram.build = "50M"
ram.runtime = "50M"

[install]
    [install.domain]  type = "domain"
    [install.path]    type = "path"
    [install.init_main_permission] type = "group"   # not saved as a setting, seeds the SSOwat permission
    [install.admin]   type = "user"
    [install.password] type = "password"            # user-provided password questions are NOT auto-saved as settings

[resources]
    [resources.sources.main]
    url = "..."; sha256 = "..."
    # autoupdate.strategy = "latest_github_tag"   # feeds autoupdate_app_sources.py

    [resources.system_user]      # provisions/deprovisions the unix user $app
    [resources.install_dir]      # /var/www/$app -> $install_dir setting
    [resources.data_dir]         # /home/yunohost.app/$app -> $data_dir setting
    [resources.permissions]
    main.url = "/"
    [resources.ports]             # random port -> $port setting
    [resources.apt]
    packages = "mariadb-server, php8.3-foo"   # phpX.Y-* deps implicitly set $phpversion
    [resources.database]
    type = "mysql"                # -> $db_name, $db_user, $db_pwd
    # Also seen upstream: resources.nodejs / resources.ruby / resources.go / resources.composer
    # (these replaced hand-rolled _common.sh version-pinning + install logic; prefer the resource
    # over a custom nodejs/ruby install helper in _common.sh if the packaging_format v2 resource exists)
```

## Script lifecycle conventions (from example_ynh's own history)

- **Ordering inside install/upgrade**: app config files (`ynh_config_add`) come *before* system configuration (nginx/php-fpm/systemd/fail2ban/logrotate). This was a deliberate reorg upstream — don't interleave arbitrarily.
- **Upgrade must stop the service before "ensure downward compatibility"/file moves**: most apps need to not be running while their files are being moved/rewritten. Stop systemd first, then do settings migration + `ynh_setup_source`, then reapply system config, then start.
- **`ynh_setup_source` on upgrade** should pass `--full_replace --keep=".env data"` (or whatever your app's persistent paths are) so stale files from the old version don't linger, while explicitly preserving anything user/data-owned.
- **Use `ynh_app_setting_set_default`** (not `ynh_app_setting_set`) in upgrade scripts for settings that may not exist on older installs — it's a no-op if the setting is already set, so upgrades from any prior version stay idempotent.
- **remove/restore must be symmetric with install**, in *reverse* order for remove (service integration removed before systemd unit removed before nginx/phpfpm config removed — mirrors install's config-then-system-then-service ordering, undone last-in-first-out).
- **Don't delete logs on app removal** — leave `/var/log/$app` behind (upstream fixed this; deleting logs on `ynh_remove` destroys debugging evidence users/maintainers need after an uninstall-reinstall cycle).
- **`data_dir` should not be world/www-data readable by default** — apply tighter ownership than the install_dir unless the app specifically needs the web server to read it.
- **`ynh_setup_source`/backup do not touch `$data_dir` during the automatic pre-upgrade safety backup** (it can be huge) — data_dir is also not purged on remove unless `--purge` is passed. Don't assume data survives only because you called `ynh_backup "$data_dir"`; the safety-backup path explicitly skips it.
- **Backup/restore must not restore the database twice** — this was a real shipped bug (calling `ynh_mysql_db_shell < db.sql` more than once via a duplicated section). When editing backup/restore, diff against example_ynh's current versions rather than pattern-matching an older copy of your own script.

## Hard-won lessons from this account's own packages (root cause → fix)

Each of these cost a live-server debugging cycle. Check for them proactively instead of waiting for the symptom.

**1. systemd `ProtectHome=true` silently breaks a `data_dir` under `/home`** (meshmonitor_ynh)
YunoHost's `data_dir` resource lives at `/home/yunohost.app/$app`. `ProtectHome=true` masks all of `/home` with an empty tmpfs *inside the unit's namespace before `ReadWritePaths=` is applied*, so the app gets `EACCES` trying to create its own data dir even though `ReadWritePaths` looks correct on paper. Fix: don't set `ProtectHome` at all when `data_dir` is used; `ProtectSystem=strict` + `ReadWritePaths=$data_dir` (and log dir) is enough hardening and doesn't conflict.

**2. Missing `resources.system_user` when scripts `chown "$app:..."`** (vantage_ynh)
If install/upgrade chown anything to `$app`, the `system_user` resource must be declared in `manifest.toml`. Without it, YunoHost fails provisioning `install_dir` with `Unknown system user '$app'` *before any script line runs* — the error looks like a resource-ordering bug but is really just a missing manifest block.

**3. Git "dubious ownership" (CVE-2022-24765) during install** (meshmonitor_ynh)
Recent git refuses to operate on a repo it doesn't own. If you `git clone`/`git pull` as root into a directory that ends up owned by the app's system user (or vice versa), git aborts with `fatal: detected dubious ownership in repository`. Fix: make sure the directory is owned by the user that will run git, and actually run the git commands as that user with `ynh_exec_as_app`, not as root.

**4. `config_panel.toml` `bind = "null"` can silently stop persisting a value** (cac-proxy_ynh)
The docs describe `bind = "null"` as the way to route a field through custom `get__ID()`/`set__ID()` functions in `scripts/config`. In practice this was traced (`ynh_app_config_run -x trace`) to short-circuit before the setter is ever invoked on at least one YunoHost core version — the webadmin reports a successful save, but `settings.yml`/the rendered config file never change. **Never trust that a config-panel field round-trips just because the TOML and getter/setter look right — test it end-to-end** (change the value via the webadmin or `yunohost app config set`, then check the setting actually changed on disk) before considering the feature done.

**5. `nginx merge_slashes` is not valid inside a `location {}` block** (cac-proxy_ynh)
It's an `http`/`server`-level-only directive; putting it in an app's location-scoped nginx template makes `nginx -t`/reload fail outright ("directive is not allowed here"). If double-slash collapsing in a proxied path is a problem, fix it in the app itself (re-insert the "//" after nginx normalizes it) rather than trying to disable `merge_slashes` from a per-app config template.

**6. TOML `default = "null"` is a syntax/semantics bug, not "no default"** (misp_ynh)
To express "no default value" for a manifest question, omit the `default` key entirely — don't write the bare word `null` as a quoted string default. It parses as the literal string `"null"`, not as "unset."

**7. systemd units for forking/slow-shutdown daemons need real iteration, not guesses** (yacy_ynh, a Java app)
`Type=forking` requires a `PIDFile=` that matches where the app *actually* writes its pidfile relative to `$data_dir`/its working directory — get this wrong and systemd can't track the real process. Slow-shutdown apps need `TimeoutStopSec` raised so `systemctl stop` doesn't SIGKILL mid-shutdown. Don't assume the first systemd unit you write is correct; check `systemctl status $app` / `journalctl -u $app` after a real start/stop cycle and adjust `Type=`, `PIDFile=`, `Environment=`, and timeouts based on what's actually observed, not what seems reasonable.

**8. Forcing SSOwat header-auth onto an app that has its own auth is high-risk** (meshmonitor_ynh)
Wiring `sso = "true"` + an nginx `Remote-User` header + the app's own proxy-auth trust mechanism is easy to get subtly wrong (header name casing, `underscores_in_headers`, the app's own trust/allowlist config) and the failure mode is often opaque 4xx/5xx with no obvious link back to the auth wiring. Default to `sso = "false"` / the app's native login unless the upstream app has clearly documented, tested support for trusted-header or reverse-proxy auth — and budget for a full revert if it doesn't work cleanly in a live test, rather than iterating indefinitely on header edge cases.

**9. Docker-compose as an escape hatch** (misp_ynh)
For apps that are only realistically deployable as a multi-container stack (MISP's MariaDB+Redis+core+modules), packaging via `resources.apt` (docker-compose-plugin) + Jinja2-templated `docker-compose.yml`/`.env` + a `scripts/_common.sh` compose wrapper is a reasonable pattern when native `packaging_format 2` resources (single systemd unit, single apt/database resource) don't fit. It trades YunoHost's native resource lifecycle (auto backup/restore of `database`, `system_user`, etc.) for manual secret generation and manual compose lifecycle management in install/upgrade/remove/backup/restore — expect to hand-write more of what resources normally give you for free, and be extra careful that `remove` actually tears down containers/volumes and `backup`/`restore` actually captures the compose state and secrets.

## Pre-flight checklist before calling a package "done"

- [ ] `manifest.toml` has the `#:schema` line and validates against it; every question that isn't a generic (`domain`/`path`/`admin`/`password`/`init_main_permission`) type has an `ask`.
- [ ] Every `chown "$app:..."` / systemd `User=$app` has a matching `resources.system_user` block.
- [ ] `resources.data_dir` is used (not a hand-rolled directory under install_dir) for anything meant to survive `app remove` without `--purge`, and it is **not** given broader permissions than the app needs.
- [ ] `scripts/upgrade` stops the service before touching files, uses `ynh_app_setting_set_default` for settings that might not exist on old installs, and calls `ynh_setup_source --full_replace --keep=...` if replacing vendored source.
- [ ] `scripts/remove` undoes `scripts/install`'s system-configuration steps in reverse order, and does **not** delete `/var/log/$app`.
- [ ] `scripts/backup` + `scripts/restore` are symmetric (same file list, same DB dump/restore call — exactly once).
- [ ] Any systemd unit has been checked with a real start/stop cycle (`systemctl status`, `journalctl -u`), not just written from a template and assumed correct — especially `Type=`, `PIDFile=`, and hardening directives (`ProtectHome`, `ReadWritePaths`) against where `$data_dir`/`$install_dir` actually live.
- [ ] If there's a `config_panel.toml`, every field that's supposed to persist has been round-tripped for real (set a value, confirm it changed on disk / took effect), not just read for correctness.
- [ ] `.gitignore` covers IDE/editor cruft (`.idea/`, `*.iml`, `.vscode/`) — don't commit local editor project files into an app package repo.
- [ ] If this app could plausibly run through `package_linter`/`package_check` (YunoHost's CI tooling), those are the authoritative pass/fail gate for app-store submission — prefer running them over guessing whether something is "linter-clean."

## Where to verify against ground truth

- `example_ynh` in this account (this repo) — canonical, actively-maintained template; scripts/manifest here reflect current helpers, not stale training-data syntax.
- `doc.yunohost.org/dev/packaging` — official packaging docs (referenced directly in this repo's manifest.toml comments and config_panel.toml.example).
- `doc/` folder convention: `DESCRIPTION.md`, `PRE_INSTALL.md`, `POST_INSTALL.md`, `PRE_UPGRADE.md`, `POST_UPGRADE.md`, `ADMIN.md` (+ `_fr` variants), `doc/screenshots/` — fill these in per-app rather than leaving placeholders, they render in the app catalog / webadmin.
