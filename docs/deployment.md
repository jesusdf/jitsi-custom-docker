# Deployment Manual

This manual takes you from an empty host to a running Jitsi Meet server, then
through the things you will need to do afterwards: adding a domain, rotating a
secret, upgrading Jitsi, and working out what went wrong when something does
not come up.

It assumes you are comfortable with Docker Compose and with reverse proxies in
general. It does not assume you know Jitsi's internals.

For the reasoning behind the design, see [design.md](design.md).

---

## Chapter 1. Before You Begin

### 1.1 What the host needs

- Docker Engine 24 or later with the Compose plugin.
- Ports 80/tcp, 443/tcp, 443/udp and 10000/udp reachable from the internet.
- DNS records for every domain you intend to serve, pointing at the host.

Nothing else. The stack brings its own reverse proxy, so the host must **not**
have nginx, Apache or anything else holding ports 80 and 443.

> **If the host already runs a reverse proxy,** you are about to take its
> ports. Read chapter 5 first: the vhosts it serves have to move into the stack
> before you stop it, or they go dark.

### 1.2 What the network needs

Only three ports have to be open inbound:

| Port | Protocol | Why |
|---|---|---|
| 80 | TCP | ACME challenges and the redirect to HTTPS |
| 443 | TCP | HTTPS, and TURN over TLS for clients behind strict firewalls |
| 443 | UDP | STUN and TURN over UDP, which is the better media path |
| 10000 | UDP | Direct media, used whenever the client's network allows it |

The TURN relay range (`TURN_RELAY_MIN_PORT`..`TURN_RELAY_MAX_PORT`) does
**not** need to be open. Those ports face the video bridge inside the stack's
own network, never the client.

[network-requirements.svg](network-requirements.svg) says the same thing in a
form you can send to whoever runs the firewall, without mentioning Jitsi
internals.

---

## Chapter 2. A First Deployment

### 2.1 Fetch the repository

```sh
git clone <repository-url> jitsi
cd jitsi
```

### 2.2 Write the environment file

```sh
cp .env.example .env
```

Open `.env`. Every setting is documented inline; these are the ones you cannot
leave alone:

| Variable | What to put |
|---|---|
| `JITSI_VERSION` | Any `stable-*` tag, for example `stable-11031` |
| `JITSI_DOMAINS` | Comma-separated. All of them share one room namespace |
| `PUBLIC_URL` | The primary domain, with scheme. Signalling always goes here |
| `TURN_HOST`, `TURNS_HOST` | Usually the primary domain, because the certificate has to match |
| `DOCKER_HOST_ADDRESS` | The host's address on its local network |
| `JWT_APP_ID`, `JWT_APP_SECRET` | If you use JWT authentication |

Then fill the secrets:

```sh
./scripts/gen-secrets.sh
```

It only touches variables that are present and empty, so it is safe to run
again after adding one. To rotate a secret, blank it first and re-run.

### 2.3 Provide a certificate

You have two options. The simplest is to supply one you already have:

```sh
cp /path/to/fullchain.pem conf/certs/
cp /path/to/privkey.pem   conf/certs/
```

With `TLS_MODE=files`, which is the default, that is all.

To have the stack issue it instead, see chapter 4.

### 2.4 Declare the sub-path routes

Skip this if your domains serve nothing but Jitsi.

```sh
cp conf/routes.conf.example conf/routes.conf
```

Each line says that, on one domain, requests matching a path should go
somewhere other than Jitsi:

```
meet.example.org   ^/apps/waiting-room/   https://app.example.org
```

The format is covered in section 3.2.

### 2.5 Start it

```sh
docker compose up -d
docker compose logs -f init nginx
```

`init` runs first and exits; everything else waits for it. A healthy start
looks like this:

```
[init] downloaded mod_token_moderation.lua
[init] room notifications disabled
[init] moderation requires a token
[init] ready
[nginx] serving meet.example.org
[nginx] serving team.meet.example.org
[nginx] configuration generated
```

`room notifications disabled` is expected unless you set `NOTIFICATION_URL`
(section 3.4). It is an optional feature, not a failure.

### 2.6 Confirm it works

```sh
# The page loads and the certificate is the right one
curl -sI https://meet.example.org | head -1

# TURN answers on 443/tcp, separated from HTTPS by ALPN
openssl s_client -connect meet.example.org:443 -alpn stun.turn </dev/null 2>&1 | grep -i 'ALPN\|Verify return'
```

Then open a room in two browsers on different networks. If both see and hear
each other, media is working.

---

## Chapter 3. Configuration

### 3.1 How settings reach the containers

Every variable in `.env` is passed to every container. The compose file
deliberately does not list variable names, so any variable the Jitsi images
support works without editing it -- including ones added in a later release.

This is also why you can consult the [Jitsi environment variable
reference](https://jitsi.github.io/handbook/docs/devops-guide/devops-guide-docker)
and expect anything you find there to work.

### 3.2 Sub-path routes

`conf/routes.conf` is whitespace-separated, one rule per line:

```
<domain>  <path-regex>  <target>  [option...]
```

| Field | Notes |
|---|---|
| `domain` | Must be one of the domains in `JITSI_DOMAINS` |
| `path-regex` | Matched case-insensitively against the request path |
| `target` | An upstream URL, or `redirect:<status>:<location>` |

Two options are available:

| Option | Effect |
|---|---|
| `mirror=<url>,<url>` | Each URL receives a copy of the request; responses are discarded |
| `host=<name>` | Overrides the `Host` header, for an upstream that serves several tenants |

To reach a service running on the Docker host rather than in the stack, use
`host.docker.internal` as the hostname.

The first matching rule wins, as with any nginx location. A worked example:

```
# Waiting room and its API, per tenant
meet.example.org   ^/apps/waiting-room/   https://app.example.org
meet.example.org   ^/rest/                https://app.example.org

# Notifications go to one backend and are copied to two others
meet.example.org   ^/notify/              https://events.example.org  mirror=https://a.example.org,https://b.example.org

# A third-party API that needs its own Host header
meet.example.org   ^/translate/           https://api.vendor.example  host=api.vendor.example

# A retired page
meet.example.org   ^/old-close\.html$     redirect:302:/static/close2.html
```

Changes take effect on `docker compose restart nginx`.

### 3.3 Prosody plugins

The token moderation plugin ships enabled by default: it grants moderator
rights from a `moderator` claim in the JWT. Remove it from `PROSODY_PLUGINS`
and `XMPP_MUC_MODULES` if you do not use JWT authentication.

To add more, list the URLs space-separated and name the modules:

```dotenv
PROSODY_PLUGINS=https://example.org/a/mod_one.lua https://example.org/b/mod_two.lua
XMPP_MUC_MODULES=mod_one,mod_two
```

`init` downloads each into `conf/prosody/plugins/` on every start. **A failed
download is not fatal:** the copy already on disk stays and the stack comes up
with it. Look for this in the log:

```
[init] WARNING: could not download mod_token_moderation.lua; keeping the copy already on disk
```

> **Pin plugins to a commit, not to a branch.** A plugin is written against a
> particular Prosody API, and Prosody's is moving: `stable-11031` ships Prosody
> 13, where the old `is_admin` API still works but logs
> `will be disabled in a future build` on every call. A URL ending in `/master/`
> silently changes what you deploy. Use the commit hash, and re-check the pin
> whenever you change `JITSI_VERSION`.

To configure a plugin, add a template under `conf/prosody/plugin-conf/` using
`@PLACEHOLDER@` markers, and render it from `conf/scripts/init.sh`.

The rendered file lands in `conf.d/` **next to** the configuration the Prosody
image generates, never on top of it. Prosody merges repeated `Component`
declarations key by key, so a fragment that sets options the generated file
does not set is safe.

Write fragments so that **order does not matter**: Prosody expands the `conf.d`
glob without sorting, so the load order is undefined. Two files setting the
same key would produce a result that depends on the filesystem. Give each
fragment its own keys.

To see what was actually written:

```sh
docker compose exec prosody ls /config/conf.d/
docker compose exec prosody cat /config/conf.d/stack-notification.cfg.lua
```

### 3.4 Room event notifications

An optional feature of the moderation plugin. It is off until you give it an
endpoint:

```dotenv
NOTIFICATION_URL=https://meet.example.org/notify/event
NOTIFICATION_USER=service-account
NOTIFICATION_PASSWORD=...
NOTIFICATION_USERAGENT=Jitsi-Prosody
NOTIFICATION_TIMEOUT=10
NOTIFICATION_RETRY_COUNT=5
NOTIFICATION_RETRY_DELAY=1
```

**Leave `NOTIFICATION_URL` empty and the feature is simply off.** No
configuration is written, and the plugin logs that notifications are disabled:

```
[init] room notifications disabled
```

The other `NOTIFICATION_*` values are ignored in that case, and a blank one
falls back to its default rather than producing a configuration Prosody cannot
parse.

Pointing the URL back at your own public domain is a deliberate pattern: nginx
then routes the call on to its real destination using `conf/routes.conf`, and
can mirror it to several backends without Prosody knowing.

> **If the endpoint uses a private CA,** set `EXTRA_CA_FILE` (section 3.6) or
> every notification will fail TLS verification.

### 3.5 Branding

Put your assets in `conf/branding/`. nginx serves them at `/branding/` on
every Jitsi domain.

The cleanest route is dynamic branding, which can differ per domain:

```dotenv
DYNAMIC_BRANDING_URL=https://meet.example.org/branding/dynamic-branding.json
```

For names and watermarks, create `conf/branding/custom-interface_config.js`
and copy it into `data/web/`; the image appends it to the generated
`interface_config.js`.

> **Favicons and PWA icons have no supported mechanism.** Replacing them means
> bind-mounting files over paths inside the image, which can break on upgrade.
> Do it only if you need to, and re-check after every version bump.

### 3.6 Trusting a private CA

```dotenv
EXTRA_CA_FILE=/conf/certs/internal-ca.crt
```

Put the certificate in `conf/certs/`. `init` merges it with the public roots
into `conf/certs/ca-bundle.crt` and points Prosody at the result.

---

## Chapter 4. Certificates

### 4.1 Choosing a mode

| `TLS_MODE` | Use when |
|---|---|
| `files` | You already have a certificate, from any source |
| `acme-http` | You want Let's Encrypt and do not need a wildcard |
| `acme-dns-azure` | You want Let's Encrypt and your DNS is in Azure |

### 4.2 HTTP-01

```dotenv
TLS_MODE=acme-http
ACME_EMAIL=you@example.org
```

Port 80 must be reachable from the internet. Every domain in `JITSI_DOMAINS`
goes into one certificate as a SAN, unless you override the list with
`ACME_DOMAINS`.

Wildcards are not possible over HTTP-01. Use DNS-01 if you need one.

### 4.3 DNS-01 against Azure DNS

```dotenv
TLS_MODE=acme-dns-azure
ACME_EMAIL=you@example.org
ACME_DOMAINS=meet.example.org,*.meet.example.org

AZUREDNS_SUBSCRIPTIONID=...
AZUREDNS_TENANTID=...
AZUREDNS_APPID=...
AZUREDNS_CLIENTSECRET=...
```

The service principal needs the **DNS Zone Contributor** role on the zone. You
do not need to state the resource group or the zone: acme.sh finds them.

### 4.4 Renewal

The `acme` container wakes daily and asks acme.sh to renew anything close to
expiry. After installing a new certificate it touches a marker file:

- nginx notices within five minutes and reloads.
- coturn notices and exits; the restart policy brings it back with the new
  certificate.

Nothing to schedule and no Docker socket to expose.

---

## Chapter 5. Serving Sites That Are Not Jitsi

The stack's nginx owns ports 80 and 443, so any other vhost the host used to
serve has to move into it.

### 5.1 Moving a vhost

Copy the server block into `conf/nginx/sites/`, one file per site, and make two
changes.

**First, backends.** Inside a container, `localhost` is the container. Use
`host.docker.internal`, and name the backend through a variable so nginx
resolves it per request:

```nginx
# Before
proxy_pass http://127.0.0.1:9000;

# After
set $backend "http://host.docker.internal:9000";
proxy_pass $backend;
```

**Second, certificates.** Move them under `conf/certs/` and update the paths.

The snippets a host nginx usually provides are published at the same paths, so
`include` lines need no change:

```nginx
include /etc/nginx/site-defaults.conf;      # TLS settings and the listen directive
include /etc/nginx/proxy-defaults.conf;     # the usual proxy headers
include /etc/nginx/only-trusted-hosts.conf; # your IP allow-list
include /etc/nginx/no-robots.conf;          # robots.txt
```

`site-defaults.conf` carries the `listen` directive, so your file never needs
to know which internal port the 443 splitter forwards to.

To add a snippet of your own, drop it in `conf/nginx/snippets/`; it is
published at `/etc/nginx/<name>.conf` too.

> **IP allow-lists keep working.** The splitter passes the client address
> through the PROXY protocol and `site-defaults.conf` restores it, so
> `$remote_addr` is the real client.

### 5.2 Reaching the backend

A service published as `127.0.0.1:9000` on the host cannot be reached from a
container: inside the container, `127.0.0.1` is the container. How you fix that
depends on whether the backend is itself a container.

#### If the backend is a container: share a network

This is the better answer, and it is what you should do wherever it applies.
The backend **stops publishing any port at all** and joins a network shared
with the proxy. nginx then reaches it by service name, over Docker's own
network, and the service becomes unreachable from outside the host entirely.

This stack creates the network, so nothing has to exist beforehand:

```yaml
# docker-compose.yml, already present
networks:
  edge:
    name: ${EDGE_NETWORK:-jitsi-edge}
```

In the *other* stack, declare it as external and join it:

```yaml
networks:
  jitsi-edge:
    external: true

services:
  portainer:
    networks: [default, jitsi-edge]
    # ports: no longer needed -- delete it
```

Then name the service directly in the site file:

```nginx
set $backend "http://portainer:9000";
proxy_pass $backend;
```

Compose registers each service name as a network alias on every network it
joins, so the name resolves across stacks without container names or fixed
addresses.

What this buys you over publishing a port:

| | Published port | Shared network |
|---|---|---|
| Reachable from outside the host | Yes, unless the firewall says otherwise | No, never |
| Depends on firewall rules being right | Yes | No |
| Survives the container getting a new address | Yes | Yes |
| Needs a change in the other stack | Yes | Yes |

Both need a change in the other stack, so the shared network costs nothing
extra and removes a class of mistake.

> **A shared network is a flat network.** Any container on `jitsi-edge` can
> reach any other on it. Put only the services you intend to proxy on it, not
> whole stacks.

#### If the backend runs on the host, outside Docker

Then there is no network to share, and `host.docker.internal` is the way in.
The compose file maps it to the Docker host for the `nginx` service:

```nginx
set $backend "http://host.docker.internal:7000";
```

The service has to be listening on an address the container can reach, which
loopback is not. Bind it to the Docker bridge address rather than to `0.0.0.0`,
so it is not exposed on the host's other interfaces.

### 5.3 Keeping a way in

If the console you use to redeploy this stack is itself proxied by this stack,
a configuration error locks you out: nginx fails to start, the console goes
with it, and the console is what you would have used to fix it.

Serve it here if you like, but keep a second route that does not pass through
the stack -- its own port on the host, firewalled to trusted addresses.

### 5.4 Extra listening ports

The stack publishes only 80 and 443. If a migrated vhost listened elsewhere,
add that port to the `nginx` service in `docker-compose.yml`.

---

## Chapter 6. Operating

### 6.1 Routine tasks

| Task | Command |
|---|---|
| Apply a change to `.env` | `docker compose up -d` |
| Apply a change to `routes.conf` or `sites/` | `docker compose restart nginx` |
| Re-download plugins | `docker compose up -d --force-recreate init` |
| Watch the proxy | `docker compose logs -f nginx` |
| Check the generated configuration | `docker compose exec nginx cat /etc/nginx/generated/http/10-jitsi.conf` |

### 6.2 Adding a domain

1. Append it to `JITSI_DOMAINS`.
2. Make sure the certificate covers it. With `acme-*`, also add it to
   `ACME_DOMAINS`.
3. Add its routes to `conf/routes.conf`, if any.
4. `docker compose up -d`.

### 6.3 Rotating secrets

```sh
$EDITOR .env            # blank the values you want to rotate
./scripts/gen-secrets.sh
docker compose up -d
```

Rotating `TURN_CREDENTIALS` invalidates in-flight TURN allocations. Clients
reconnect on their own.

### 6.4 Upgrading Jitsi

```sh
$EDITOR .env            # JITSI_VERSION=stable-XXXXX
docker compose pull
docker compose up -d
```

There is nothing else to reconcile. No generated configuration is frozen and no
variable names are pinned in the compose file, which is what makes an upgrade a
one-line change.

**After a major jump,** check three things:

1. `docker compose logs prosody` for options the new release no longer accepts.
2. Whether any feature flag you rely on was renamed. Compare `.env` against the
   release's `env.example`.
3. Branding, if you bind-mount files over paths inside the image.

To roll back, put the old tag back and run the same two commands.

---

## Chapter 7. Deploying from Portainer

Portainer is the intended way to run this stack. Use **Stacks -> Add stack ->
Repository** and point it at the Git repository: the repository carries the
compose file *and* `conf/`, which the containers bind-mount, so the web editor
and file upload options are not enough on their own.

Two things about repository stacks catch people out. Both are dealt with below.

### 7.1 Create the stack

1. **Stacks -> Add stack**, give it a name, choose **Repository**.
2. Repository URL, reference (`refs/heads/main`) and, for a private
   repository, credentials.
3. Compose path: `docker-compose.yml`.
4. Under **Environment variables**, add the contents of `.env.example` with
   your values. Portainer writes these to an `.env` file next to the compose
   file, which is where the stack reads them from.
5. Deploy.

Optionally enable **GitOps updates** so Portainer re-pulls on a schedule or
from a webhook. Your own files under `conf/` are gitignored, so a pull never
overwrites them.

### 7.2 The first catch: bind mounts and where the daemon looks

The compose file mounts `conf/` into several containers. Compose turns a
relative path into an absolute one using the directory the compose file is in,
and hands that to the Docker daemon, which resolves it **on the host**.

For a repository stack, Portainer clones into its own `/data/compose/<id>`. If
Portainer's `/data` is a named volume, that path does not exist on the host,
and the daemon silently creates empty directories instead. The symptom is
nginx failing to start with configuration it cannot find.

Two ways to avoid it:

**Tell Portainer where the repository lives on the host.** Recent Portainer
versions offer a local filesystem path for relative volumes when creating the
stack. Set it, and `conf/` resolves correctly with no other change. This is the
better option because Git stays the source of truth.

**Or point the stack at an absolute path.** Works on any Portainer version:

```sh
# On the host, once
git clone <repository-url> /opt/jitsi
```

Then set, in the stack's environment variables:

```dotenv
STACK_DIR=/opt/jitsi
CONFIG=/opt/jitsi/data
```

The trade-off is that `/opt/jitsi` is now updated with `git pull` rather than
by Portainer.

To check which situation you are in, deploy and look at the init container:

```sh
docker compose logs init
```

If it reports missing files or nginx cannot find its configuration, the mounts
did not resolve.

### 7.3 The second catch: the environment file

`.env` is gitignored -- it holds secrets -- so a fresh clone does not have one.
Compose refuses to start a service whose `env_file` is missing, which would
make a repository stack fail before anything ran.

The compose file therefore marks it `required: false`, and the init container
checks the variables that actually matter instead:

```
[init] the environment is missing: JITSI_VERSION JITSI_DOMAINS PUBLIC_URL STACK_SUBNET
[init] ERROR: set them in .env, or in the stack's environment variables, and deploy again
```

Init exits non-zero, so nothing else starts on a half-configured stack.

In normal use this never appears: Portainer writes the `.env` file from the
variables you entered in step 4.

### 7.4 Files Portainer does not carry

Anything gitignored has to be placed on the host once, under whatever directory
`STACK_DIR` names:

| Path | What |
|---|---|
| `conf/certs/` | Certificate and key, when `TLS_MODE=files`. Any extra CA |
| `conf/routes.conf` | Sub-path routes. Copy from `conf/routes.conf.example` |
| `conf/nginx/sites/` | Site files for anything that is not Jitsi |
| `conf/branding/` | Logo, background, dynamic branding JSON |

`conf/prosody/plugins/` fills itself: the init container downloads into it.

### 7.5 Updating

| To change | Do this |
|---|---|
| A setting | Edit the stack's environment variables, redeploy |
| The Jitsi version | Change `JITSI_VERSION`, redeploy with **Re-pull image** |
| Routes or site files | Edit them under `STACK_DIR`, then restart `nginx` |
| The stack itself | **Pull and redeploy**, or let GitOps do it |

> **Keep a way into Portainer that does not pass through this stack.** If its
> vhost is served here and nginx fails to start, the console you would use to
> fix it goes down with it. See section 5.3.

---

## Chapter 8. When It Does Not Work

### The stack will not start

```sh
docker compose logs init
```

`init` runs before everything else, so a failure there stops the rest. It
reports exactly what it could not do.

### nginx will not start

```sh
docker compose logs nginx
docker compose exec nginx nginx -t
```

The usual causes:

| Message | Cause |
|---|---|
| `cannot load certificate` | `TLS_CERT_FILE` points at a file that is not there |
| `host not found in upstream` | A drop-in site names a backend directly instead of through a variable |
| `unknown directive` | A snippet copied from a host nginx uses a module this image lacks |

### The page loads but nobody connects

Check, in order:

1. **Signalling.** In the browser console, look for the WebSocket to
   `PUBLIC_URL`. A failure here is usually CORS or a certificate that does not
   cover the domain that served the page.
2. **The bridge.** `docker compose logs jvb`. If it never joins the brewery
   MUC, the XMPP credentials are wrong.
3. **Media.** If signalling works but audio and video do not, it is almost
   always the advertised address. See below.

### Media fails from some networks only

The video bridge advertises an address for clients to send media to. If it
advertises the wrong one, clients on some networks reach it and others do not.

```sh
docker compose exec jvb grep -A3 static-mappings /config/jvb.conf
```

Set `JVB_ADVERTISE_IPS` to the host's public address instead of relying on STUN
discovery. While you are there, confirm TURN is reachable, since that is the
fallback when direct media fails:

```sh
openssl s_client -connect <TURN_HOST>:443 -alpn stun.turn </dev/null 2>&1 | head -5
```

### Room notifications never arrive

```sh
docker compose logs prosody | grep -i notification
```

A TLS error means the endpoint's CA is not trusted: set `EXTRA_CA_FILE`
(section 3.6). A 404 or 502 means nginx is not routing the path -- check the
matching rule in `conf/routes.conf`.

### An IP allow-list blocks everyone

That means the real client address is not reaching the server block. The site
file must include `/etc/nginx/site-defaults.conf`, which is what restores the
address from the PROXY protocol header.
