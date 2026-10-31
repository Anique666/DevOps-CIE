# Secure Python Worker for File Processing

**Fedora + Docker + SELinux + Minikube laboratory implementation and viva guide**

This project implements a small Flask worker that counts the words in a text
file. The worker is containerised, runs as a non-root user, is restricted by
Docker and by **SELinux Enforcing** on Fedora, and is deployed to Kubernetes
(Minikube) with a ClusterIP Service.

> **Fedora note:** the original question mentions AppArmor. Fedora uses
> **SELinux** as its primary mandatory access control system, so this
> implementation uses SELinux and does **not** install or configure AppArmor.
> SELinux is never disabled or switched to Permissive.

---

## Verification status (this environment)

| Phase | Status | Evidence |
|---|---|---|
| 1. Flask API | Implemented and tested | 18/18 API tests pass |
| 2. Docker image | Built and run | `cie-worker:1.0`, healthy |
| 3. Custom network | Created and tested | `cie-net`, inter-container HTTP 200 |
| 4. SELinux controls | Enforced and tested | AVC `denied { read } ... permissive=0` |
| 5. Inspection / troubleshooting | Tested | inspect, logs, exit codes, three failures |
| 6. Minikube deployment | Deployed and tested | 1/1 Running, ClusterIP, 18/18 tests |
| 7. End-to-end | Tested | Docker and Kubernetes |
| `sudo ausearch` | Manual only | `sudo` needs a password here; AVC read via `journalctl` |
| AppArmor | Not used | Fedora/SELinux implementation |

Environment observed while building this lab:

| Component | Version / state |
|---|---|
| OS | Fedora Linux 44 (Workstation) |
| Kernel | 6.19.10-300.fc44.x86_64 |
| SELinux | `targeted`, **Enforcing** |
| Docker | 29.7.2, `overlayfs`, `--selinux-enabled` |
| Python (host) | 3.12.15 |
| Python (image) | 3.12.16 |
| Flask / gunicorn | 3.1.2 / 23.0.0 |
| Minikube | v1.39.0, docker driver |
| Kubernetes | v1.37.0, containerd 2.3.4 |
| kubectl | v1.37.1 |

Container IDs, pod hashes, IP addresses, MCS categories and timestamps vary on
every run. The structure of the outputs is what matters.

---

## Quick start

From the project directory:

```bash
cd /home/anique/DevOps_LabExam/cie

# 1. Build the image
./scripts/build.sh

# 2. Run the hardened worker with a private SELinux label
./scripts/run.sh

# 3. Run the API test suite
./scripts/test.sh

# 4. Demonstrate SELinux denial + permitted access (restarts the worker)
./scripts/selinux-demo.sh

# 5. Deploy to Minikube
./scripts/k8s-deploy.sh

# 6. Access the Kubernetes Service locally
kubectl -n cie port-forward svc/cie-worker 8080:80
# In a second terminal:
BASE_URL=http://127.0.0.1:8080 ./scripts/test.sh
```

If a command is not available on a clean machine, see
[Prerequisites](#b-prerequisites).

---

## Table of contents

- [A. Experiment overview](#a-experiment-overview)
- [B. Prerequisites](#b-prerequisites)
- [C. Project structure](#c-project-structure)
- [D. Step-by-step implementation](#d-step-by-step-implementation)
  - [Phase 1 — Flask application](#phase-1--flask-application)
  - [Phase 2 — Docker containerisation](#phase-2--docker-containerisation)
  - [Phase 3 — Docker networking](#phase-3--docker-networking)
  - [Phase 4 — SELinux security](#phase-4--selinux-security)
  - [Phase 5 — Inspection and troubleshooting](#phase-5--inspection-and-troubleshooting)
  - [Phase 6 — Kubernetes / Minikube](#phase-6--kubernetes--minikube)
  - [Phase 7 — End-to-end verification](#phase-7--end-to-end-verification)
- [E. SELinux deep dive](#e-selinux-deep-dive)
- [F. Docker deep dive](#f-docker-deep-dive)
- [G. Kubernetes / Minikube deep dive](#g-kubernetes--minikube-deep-dive)
- [H. Troubleshooting](#h-troubleshooting)
- [I. Viva preparation](#i-viva-preparation)
- [J. Complete demonstration checklist](#j-complete-demonstration-checklist)
- [K. Limitations and manual steps](#k-limitations-and-manual-steps)
- [Appendix — API and command reference](#appendix--api-and-command-reference)

---

## A. Experiment overview

### Aim

Build a secure Python file-processing worker, run it in Docker with a
designated input directory, apply Fedora-compatible mandatory access control
with SELinux, inspect the security configuration, and deploy the same worker to
Minikube while exposing only the required application interface.

### Problem statement

A document-processing company runs a Python worker in Docker. The worker must
read files from a designated directory but must not modify protected system
files or perform unauthorised operations. The worker must remain usable when
given a correctly labelled read-only input directory, and a failed request
caused by a wrong mount path or bad permissions must be diagnosable and
correctable without removing the security restrictions.

### Objectives

1. Implement `/health` and `/process` endpoints that return structured JSON.
2. Reject arbitrary paths, path traversal, missing files and unreadable files.
3. Build a reproducible non-root Docker image that reads a mounted input
   directory and cannot write to it.
4. Create a custom Docker bridge network and demonstrate inter-container
   communication without adding unnecessary services.
5. Enforce SELinux on Fedora using correct file contexts, Docker `:Z` labels,
   unprivileged container settings and real AVC evidence.
6. Inspect the container, logs, exit status and SELinux contexts.
7. Diagnose and correct a mount-path and a permission failure without
   weakening security.
8. Deploy to Minikube with a Deployment, ConfigMap and ClusterIP Service.
9. Provide a reproducible end-to-end test sequence and viva explanations.

### Expected outcome

* `GET /health` returns HTTP 200 with `"status":"ok"` when `/data` is readable.
* `GET /process?file=sample.txt` returns HTTP 200 and `"word_count":114`.
* `../etc/passwd`, `/etc/passwd`, encoded traversal and `.` return HTTP 400.
* A missing file returns HTTP 404; an unreadable file returns HTTP 403.
* A container without the `:Z` label gets a real SELinux denial, recorded as an
  AVC with `permissive=0`.
* Writing to `/data` or `/etc` fails with `Read-only file system`.
* Reading `/etc/shadow` as UID 10001 fails with `Permission denied` (DAC).
* The Docker container is healthy and the Kubernetes Pod is `1/1 Running`.
* The Service is `ClusterIP` and is reached locally only through
  `kubectl port-forward`.

### Architecture

```text
Fedora host (SELinux Enforcing, targeted policy)
│
├── data/sample.txt
│     user_home_t  ──(:Z relabel)──►  container_file_t:s0:cX,cY
│
├── Docker daemon (--selinux-enabled)
│   │
│   ├── bridge network: cie-net (172.19.0.0/16)
│   │   ├── cie-worker  (container_t, UID 10001)
│   │   │     ├── /data  (bind, ro, Z)
│   │   │     ├── /      (read-only rootfs)
│   │   │     ├── /tmp   (tmpfs, noexec, nosuid)
│   │   │     └── caps: none, no-new-privileges
│   │   └── one-off test client (python:3.12-slim)
│   │
│   └── published: 127.0.0.1:5000 -> 5000/tcp
│
└── Minikube (docker driver, containerd, SELinux disabled inside)
    └── namespace cie
        ├── ConfigMap cie-input  (sample.txt, read-only)
        ├── Deployment cie-worker
        │     non-root, caps dropped, RO rootfs, seccomp RuntimeDefault
        └── Service cie-worker  ClusterIP:80 -> 5000
              └── kubectl port-forward 8080:80
```

### Design decisions at a glance

| Decision | Reason |
|---|---|
| Flask + gunicorn | Small explicit HTTP API; gunicorn avoids the Flask development server in the container |
| `python:3.12-slim` | Small, reproducible base with a current Python |
| Fixed UID/GID 10001 | Non-root runtime and reproducible Kubernetes `securityContext` |
| Bind mount `:ro,Z` | Runtime input is not baked into the image; read-only + private SELinux label |
| Custom bridge network | Demonstrates isolation and name-based service discovery |
| `--read-only`, `--cap-drop ALL`, `no-new-privileges` | Least privilege and immutable runtime |
| No custom SELinux policy | Standard `container_t` policy plus correct labels is sufficient |
| ConfigMap in Kubernetes | Declarative, read-only input without host bind-mount labels |
| ClusterIP + port-forward | No NodePort/LoadBalancer; only the required interface is reachable |

---

## B. Prerequisites

### Required software

* Fedora Linux (tested on Fedora 44).
* Docker Engine with SELinux support.
* Python 3.12 (only needed if you want to run the app outside Docker).
* curl and jq for the test scripts.
* Minikube and kubectl.
* SELinux userspace tools and audit tools.

### Fedora installation commands

```bash
# Docker and basic tools
sudo dnf install -y docker jq curl

# SELinux and audit tools
sudo dnf install -y policycoreutils policycoreutils-python-utils audit setools-console

# Kubernetes client (Fedora package) — alternatively install kubectl from
# https://kubernetes.io/docs/tasks/tools/
sudo dnf install -y kubernetes-client

# Minikube
curl -LO https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
sudo install minikube-linux-amd64 /usr/local/bin/minikube
rm -f minikube-linux-amd64
```

Enable Docker and auditd:

```bash
sudo systemctl enable --now docker
sudo systemctl enable --now auditd

# Allow your user to use Docker without sudo (log out/in or use newgrp)
sudo usermod -aG docker "$USER"
newgrp docker
```

### Version-check commands

```bash
cat /etc/os-release
uname -r
docker --version
docker info --format '{{.ServerVersion}} {{.Driver}} {{json .SecurityOptions}}'
python3 --version
minikube version
kubectl version --client
getenforce
sestatus
```

Observed in this lab:

```text
Fedora Linux 44 (Workstation Edition)
6.19.10-300.fc44.x86_64
Docker version 29.7.2
29.7.2 overlayfs ["name=seccomp,profile=builtin","name=selinux","name=cgroupns"]
Python 3.12.15
minikube version: v1.39.0
Client Version: v1.37.1
Enforcing
```

### Required permissions

* Membership of the `docker` group to build/run containers without `sudo`.
* `sudo` for `ausearch` (the audit log is root-readable only) and for
  `restorecon` if you want to restore host labels after the lab.
* No root is required inside the container; the image runs as UID 10001.

> In this lab shell, `sudo` required a password. The AVC evidence was therefore
> read with `journalctl`, which exposes the same audit records to the logged-in
> user. The `sudo ausearch` command is documented for manual use.

### SELinux prerequisites

```bash
getenforce          # must print Enforcing
sestatus            # SELINUXTYPE=targeted, mode enforcing
```

Do **not** run `setenforce 0`, edit `/etc/selinux/config` to `permissive`, or
use `--privileged`/`label=disable` to make the lab work. The point of the lab
is to make correct labelling work under enforcement.

### Minikube prerequisites

* Docker driver (default here).
* At least 2 CPUs and 4 GB of memory.
* The Docker image must be loaded into Minikube's runtime; this lab does not
  push to a registry.

```bash
minikube start --driver=docker --cpus=2 --memory=4096
minikube status
kubectl get nodes
```

If a Minikube profile already exists, Minikube refuses to change its memory
size. To change resources, delete and recreate the profile:

```bash
minikube delete
minikube start --driver=docker --cpus=2 --memory=4096
```

---

## C. Project structure

```text
cie/
├── app/
│   ├── app.py                 Flask worker (API + security validation)
│   └── requirements.txt       Pinned Flask and gunicorn
├── data/
│   └── sample.txt             Sample input; exactly 114 words
├── docker/
│   └── Dockerfile             Hardened non-root image
├── kubernetes/
│   ├── namespace.yaml         Namespace cie
│   ├── configmap.yaml         Read-only sample input for the Pod
│   ├── deployment.yaml        Deployment with securityContext + probes
│   └── service.yaml           ClusterIP Service
├── scripts/
│   ├── build.sh               Build the image
│   ├── run.sh                 Create network + run hardened container
│   ├── test.sh                API test suite (18 checks)
│   ├── selinux-demo.sh        Denied vs permitted SELinux read
│   ├── inspect.sh             Security inspection evidence
│   ├── k8s-deploy.sh          Start Minikube, load image, apply manifests
│   └── stop.sh                Remove the Docker worker
├── docs/
│   └── SECURITY.md            Security model, denial evidence, limitations
├── .dockerignore              Keeps data/docs/k8s out of the build context
├── .gitignore
└── README.md                  This guide
```

Important file explanations:

| Path | Purpose |
|---|---|
| `app/app.py` | Reads only a validated basename inside `INPUT_DIR`; returns JSON; maps errors to 400/403/404/413/500/503. |
| `data/sample.txt` | Deliberately kept outside the image. Mounted read-only at `/data`. |
| `docker/Dockerfile` | Installs pinned dependencies, creates UID 10001, makes code read-only, sets healthcheck and gunicorn command. |
| `kubernetes/configmap.yaml` | Supplies `sample.txt` as a read-only volume. This replaces host bind mounts inside the cluster. |
| `kubernetes/deployment.yaml` | One replica, non-root, no capabilities, read-only rootfs, seccomp, probes, resource limits. |
| `kubernetes/service.yaml` | ClusterIP on port 80, targetPort `http` (5000). No external exposure. |
| `scripts/test.sh` | Reproducible 18-check acceptance test against any `BASE_URL`. |
| `scripts/selinux-demo.sh` | Resets the lab directory label, runs the no-`:Z` denial, reads the AVC, then runs with `:Z`. |
| `docs/SECURITY.md` | Concise security evidence and K8s/SELinux limitations. |

---

## D. Step-by-step implementation

### Phase 1 — Flask application

#### What we are doing

Create a minimal API with two endpoints:

* `GET /health` — liveness/readiness and input-directory status.
* `GET /process?file=<name>` — word count for one file in `INPUT_DIR`.

#### Why

The worker must be simple enough to explain in a viva, but it must not become a
generic file-read service. The API accepts a **filename**, never a path. The
application independently validates the name and the resolved path, so a bug in
one check does not automatically expose the filesystem.

#### Files

* `app/app.py`
* `app/requirements.txt`
* `data/sample.txt`

#### Key implementation points

```python
INPUT_DIR = Path(os.environ.get("INPUT_DIR", "/data")).resolve()
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
```

`SAFE_NAME` accepts one path component only. It must start with an
alphanumeric character, which rejects `.`, `..`, hidden files, slashes and
absolute paths.

```python
if (raw_name != os.path.basename(raw_name)
        or not SAFE_NAME.fullmatch(raw_name)
        or raw_name in (".", "..")):
    return _error("invalid_filename", "...", 400)
```

Defence 1: reject anything that is not a plain basename.

```python
target = (INPUT_DIR / raw_name).resolve(strict=True)
target.relative_to(INPUT_DIR)   # raises ValueError if outside
```

Defence 2: resolve symlinks and require the result to stay inside
`INPUT_DIR`. A symlink pointing at `/etc/passwd` resolves outside and is
rejected.

Other safeguards:

* Only regular files are read.
* Files larger than 1 MiB return HTTP 413.
* `PermissionError` returns HTTP 403, not a stack trace.
* Missing files return HTTP 404.
* Unknown endpoints and wrong methods return JSON errors.
* The app opens files read-only and never writes.

#### Run locally (optional, development only)

```bash
cd app
python3 -m venv /tmp/cie-venv
. /tmp/cie-venv/bin/activate
pip install -r requirements.txt
INPUT_DIR="$PWD/../data" python3 app.py
```

In another terminal:

```bash
curl -s http://127.0.0.1:5000/health | jq .
curl -s 'http://127.0.0.1:5000/process?file=sample.txt' | jq .
```

Expected:

```json
{
  "input_dir": "/home/anique/DevOps_LabExam/cie/data",
  "input_dir_exists": true,
  "input_dir_readable": true,
  "service": "cie-worker",
  "status": "ok"
}
```

```json
{
  "character_count": 733,
  "file": "sample.txt",
  "service": "cie-worker",
  "size_bytes": 733,
  "status": "ok",
  "word_count": 114
}
```

#### Verify the word count

```bash
wc -w data/sample.txt
python3 -c "print(len(open('data/sample.txt').read().split()))"
```

Both print `114`.

#### Error behaviour

| Request | Expected |
|---|---|
| `/process?file=sample.txt` | 200, `word_count: 114` |
| `/process` | 400, `missing_file_parameter` |
| `/process?file=../etc/passwd` | 400, `invalid_filename` |
| `/process?file=/etc/passwd` | 400, `invalid_filename` |
| `/process?file=..%2F..%2Fetc%2Fpasswd` | 400 |
| `/process?file=.` | 400 |
| `/process?file=missing.txt` | 404, `file_not_found` |
| `/process?file=sample.txt` when `/data` is unreadable | 403, `file_inaccessible` |
| `/process?file=sample.txt` when `/data` is missing | 500, `input_directory_unavailable` |
| `POST /process` | 405 |
| `/does-not-exist` | 404, `not_found` |

#### Common errors

| Symptom | Cause | Fix |
|---|---|---|
| `ModuleNotFoundError: flask` | Dependencies not installed | `pip install -r app/requirements.txt` |
| Health 503 locally | `INPUT_DIR` points to the wrong place | Export the correct absolute path |
| Word count differs | Different sample file or trailing content | Compare with `wc -w` |
| 403 locally | File/dir permissions or SELinux | Check `ls -ld`, `ls -Z`, and AVC logs |

---

### Phase 2 — Docker containerisation

#### What we are doing

Build `cie-worker:1.0` from `docker/Dockerfile`, run it as UID 10001, and mount
the host `data/` directory read-only at `/data`.

#### Why

Containerisation makes the runtime reproducible: the same Python, Flask and
gunicorn versions run on any Docker host. The image contains **code and
dependencies only**; input data is supplied at runtime. That separation is what
allows the same image to be used with a host bind mount in Docker and a
ConfigMap in Kubernetes.

#### Dockerfile walkthrough

```dockerfile
FROM python:3.12-slim
```

Small official Python image; no compiler toolchain is needed because Flask and
gunicorn are pure Python.

```dockerfile
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    INPUT_DIR=/data
```

* No `.pyc` writes: the root filesystem is read-only at runtime.
* Unbuffered logs: `docker logs` shows requests immediately.
* No pip cache in the image.
* Default input directory.

```dockerfile
RUN groupadd --gid 10001 app \
    && useradd --uid 10001 --gid 10001 --no-create-home \
       --home-dir /app --shell /usr/sbin/nologin app
```

A fixed non-root identity. `--no-create-home` and `nologin` reduce unnecessary
surface. The fixed UID/GID is reused in Kubernetes.

```dockerfile
COPY app/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt \
    && rm -f requirements.txt
```

Dependencies are installed as root before switching users.

```dockerfile
COPY app/app.py ./app.py
RUN chown -R root:root /app && chmod -R a-w /app
USER 10001:10001
```

Code is root-owned and not writable by the runtime user. The process starts as
10001.

```dockerfile
EXPOSE 5000
```

Documentation only; it does not publish the port. Publishing happens with
`-p` or Kubernetes Service/port-forward.

```dockerfile
HEALTHCHECK ... CMD python -c "import urllib.request; ... /health"
```

Docker marks the container unhealthy if `/health` fails, which also catches a
missing or unreadable `/data`.

```dockerfile
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "2", \
     "--access-logfile", "-", "--error-logfile", "-", "app:app"]
```

gunicorn is a production WSGI server; the Flask development server is not used
in the container. Access and error logs go to stdout/stderr for `docker logs`.

#### `.dockerignore`

`data/`, `kubernetes/`, `docs/`, `scripts/`, `README.md` and Python caches are
excluded. The build context stays small, and runtime data cannot accidentally
be baked into the image. Verify:

```bash
docker run --rm --entrypoint sh cie-worker:1.0 -c 'ls -ld /data'
```

Expected:

```text
ls: cannot access '/data': No such file or directory
```

#### Build

```bash
./scripts/build.sh
# equivalent:
docker build --pull -f docker/Dockerfile -t cie-worker:1.0 .
```

> **Reproducibility note.** The base image is pinned to the
> `python:3.12-slim` tag and the top-level Python packages are pinned in
> `app/requirements.txt`. For bit-for-bit reproducibility, pin the base image
> by digest (`python:3.12-slim@sha256:...`) and capture transitive Python
> packages in a lock file. `--pull` is used so a rebuild picks up base-image
> security updates; omit it if you need to use only cached layers.

Observed tail:

```text
Successfully tagged cie-worker:1.0
Repository: cie-worker:1.0
User:       10001:10001
Exposed:    map[5000/tcp:map{}]
```

#### Run

```bash
./scripts/run.sh
```

The script is idempotent: it creates `cie-net` if needed, removes an old
`cie-worker`, and waits for `/health`.

Equivalent command:

```bash
docker network create cie-net 2>/dev/null || true
docker rm -f cie-worker 2>/dev/null || true

docker run -d \
  --name cie-worker \
  --network cie-net \
  --user 10001:10001 \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --publish 127.0.0.1:5000:5000 \
  -v "$PWD/data:/data:ro,Z" \
  -e INPUT_DIR=/data \
  cie-worker:1.0
```

Flag-by-flag:

| Flag | Effect |
|---|---|
| `--user 10001:10001` | Explicit non-root identity (matches image `USER`) |
| `--read-only` | Container root filesystem cannot be modified |
| `--tmpfs /tmp:rw,noexec,nosuid,size=16m` | Only writable path; cannot execute from it |
| `--cap-drop ALL` | No Linux capabilities at all |
| `--security-opt no-new-privileges:true` | setuid/setgid cannot raise privileges |
| `--publish 127.0.0.1:5000:5000` | Reachable only from the host loopback |
| `-v ...:/data:ro,Z` | Read-only bind mount with a private SELinux label |
| `-e INPUT_DIR=/data` | Matches the mount point |

#### Verify

```bash
docker run --rm cie-worker:1.0 id
# uid=10001(app) gid=10001(app) groups=10001(app)

docker ps -a --filter name=cie-worker
# cie-worker   Up ... (healthy)   127.0.0.1:5000->5000/tcp

curl -s http://127.0.0.1:5000/health | jq .
curl -s 'http://127.0.0.1:5000/process?file=sample.txt' | jq .
```

#### Common errors

| Symptom | Cause | Fix |
|---|---|---|
| `Permission denied` on `/data` | Missing/incorrect SELinux label | Add `:Z` (or `:z` for shared data) |
| `Read-only file system` when gunicorn starts | Rootfs read-only and no `/tmp` | Keep the `--tmpfs /tmp` mount |
| Healthcheck unhealthy | `/data` missing/unreadable | Check mount target and label |
| `bind: address already in use` | Port 5000 in use | `PORT=5001 ./scripts/run.sh` |
| Image has no `/data` | By design | Mount it at runtime |

---

### Phase 3 — Docker networking

#### What we are doing

Create a user-defined bridge network `cie-net`, attach the worker, and prove
that another container can resolve and reach it by name.

#### Why

A user-defined bridge provides:

* an isolated L2/L3 segment separate from the default bridge;
* automatic DNS resolution by container name;
* explicit control over which containers can communicate.

The worker is stateless and has no database, queue or cache. Adding a
supporting service would add complexity without demonstrating anything new.
The requirement explicitly allows demonstrating the custom network
independently in this case.

#### Commands

```bash
docker network create --driver bridge cie-net
docker network inspect cie-net

# worker is already attached by scripts/run.sh
docker run --rm --network cie-net --read-only python:3.12-slim \
  python -c "import urllib.request; print(urllib.request.urlopen('http://cie-worker:5000/health', timeout=5).read().decode())"
```

Observed:

```text
Name=cie-net Driver=bridge Subnet=172.19.0.0/16 Containers=cie-worker
```

```json
{"input_dir":"/data","input_dir_exists":true,"input_dir_readable":true,"service":"cie-worker","status":"ok"}
```

The second container uses Docker's embedded DNS to resolve `cie-worker` to the
worker's address on `cie-net`. No host port is used for this request; the
published `127.0.0.1:5000` is only for the host.

#### If a supporting service were required

You would attach it to the same network and address it by service name, e.g.
`http://cache:6379`, without publishing a host port. This lab does not need it.

---

### Phase 4 — SELinux security

#### What we are doing

Run the worker under Fedora's SELinux Enforcing mode, label the input directory
with Docker `:Z`, and prove both a permitted read and a real SELinux denial.

#### 4.1 Check SELinux

```bash
getenforce
sestatus
ls -Zd data
ps -eZ | grep container_t
```

Observed:

```text
Enforcing

SELinux status:                 enabled
SELinuxfs mount:                /sys/fs/selinux
SELinux root directory:         /etc/selinux
Loaded policy name:             targeted
Current mode:                   enforcing
Mode from config file:          enforcing
Policy MLS status:              enabled
Policy deny_unknown status:     allowed

unconfined_u:object_r:user_home_t:s0 data
```

Docker must be SELinux-aware:

```bash
docker info --format '{{json .SecurityOptions}}'
```

Observed:

```json
["name=seccomp,profile=builtin","name=selinux","name=cgroupns"]
```

#### 4.2 SELinux vs AppArmor (short version)

* **SELinux** labels every subject and object with a context and enforces
  type-based rules plus MLS/MCS categories. It is the default MAC system on
  Fedora/RHEL.
* **AppArmor** attaches path-based profiles to programs. It is the default on
  Ubuntu/SUSE.
* Fedora ships SELinux policy and tools. Installing AppArmor would not be
  equivalent, would fight the distribution's defaults, and would not satisfy
  the "use the platform's MAC" intent.

A full comparison is in [Section E](#e-selinux-deep-dive).

#### 4.3 `:Z` versus `:z`

| Option | Meaning | Use when |
|---|---|---|
| `:Z` | Private, unshared label: `container_file_t` + unique MCS pair | One container needs the directory (this lab) |
| `:z` | Shared label: multiple containers may access the content | Genuinely shared read-only content |
| no option | Host label is left unchanged | The host label already matches the container policy |

With `:Z`, Docker recursively relabels the host source. The host directory
changes from `user_home_t` to `container_file_t:s0:cX,cY`, matching the
container process context `container_t:s0:cX,cY`.

> MCS categories (`cX,cY`) are generated per container start. The exact values
> in the observed outputs below are from one run; yours will differ.

#### 4.3.1 Demonstrating `:z` (shared label)

The shared label is easiest to see with two containers. Stop the private-`:Z`
worker first, reset the lab directory, then use `:z`:

```bash
docker rm -f cie-worker z1 2>/dev/null || true
chcon -R -u unconfined_u -r object_r -t user_home_t -l s0 data

# First :z container stays alive
docker run -d --name z1 --user 10001:10001 --read-only --cap-drop ALL \
  -v "$PWD/data:/data:ro,z" cie-worker:1.0 sleep 120

# Second :z container reads the same directory
docker run --rm --name z2 --user 10001:10001 --read-only --cap-drop ALL \
  -v "$PWD/data:/data:ro,z" cie-worker:1.0 \
  python -c "print(open('/data/sample.txt').read()[:60])"

# The first container can still read
docker exec z1 python -c "print(open('/data/sample.txt').read()[:60])"

ls -Zd data
```

Observed:

```text
Secure containers reduce the impact of a compromised applica
Secure containers reduce the impact of a compromised applica

system_u:object_r:container_file_t:s0 data
```

Both containers succeed and the label has **no private MCS pair** — that is
the shared nature of `:z`. Restore the private worker afterwards:

```bash
docker rm -f z1
./scripts/run.sh
ls -Zd data
# system_u:object_r:container_file_t:s0:cX,cY  (private pair returns)
```

`:z` is appropriate for shared read-only content; `:Z` is stronger when one
container owns the directory.

#### 4.4 The deliberate SELinux failure (no `:Z`)

First reset the lab directory to its normal label:

```bash
chcon -R -u unconfined_u -r object_r -t user_home_t -l s0 data
# preferred in normal use (needs root):
# sudo restorecon -F -Rv data
```

Run a read without a label:

```bash
docker run --rm --name cie-selinux-denied \
  --user 10001:10001 --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true \
  -v "$PWD/data:/data:ro" \
  cie-worker:1.0 \
  python -c "print(open('/data/sample.txt', encoding='utf-8').read()[:60])"
```

Observed:

```text
Traceback (most recent call last):
  ...
PermissionError: [Errno 13] Permission denied: '/data/sample.txt'
exit status: 1
```

The file is `0644` and the directory `0755`, so this is not ordinary DAC. The
host label remains `user_home_t`; `container_t` is not allowed to read it.

Run the same failure through the API:

```bash
docker run -d --name cie-selinux-denied \
  --user 10001:10001 --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL --security-opt no-new-privileges:true \
  -p 127.0.0.1:5001:5000 \
  -v "$PWD/data:/data:ro" \
  -e INPUT_DIR=/data \
  cie-worker:1.0

curl -sS -w '\nHTTP %{http_code}\n' http://127.0.0.1:5001/health
curl -sS -w '\nHTTP %{http_code}\n' \
  --get --data-urlencode 'file=sample.txt' \
  http://127.0.0.1:5001/process
```

Observed:

```text
{"input_dir":"/data","input_dir_exists":true,"input_dir_readable":false,
 "service":"cie-worker","status":"degraded"}
HTTP 503

{"error":{"code":"file_inaccessible",
          "message":"The worker is not permitted to read this file."},"status":"error"}
HTTP 403
```

The log shows:

```text
WARNING cie-worker Permission denied resolving sample.txt
"GET /process?file=sample.txt HTTP/1.1" 403
```

#### 4.5 AVC evidence

Read the audit stream:

```bash
journalctl --since "15 min ago" --no-pager | grep -i 'avc.*container_t'
# or, in a root shell:
sudo ausearch -m AVC -ts recent | grep -i container_t
```

Observed:

```text
AVC avc:  denied  { read } for  pid=16668 comm="python" name="sample.txt"
  dev="nvme0n1p3" ino=3181992
  scontext=system_u:system_r:container_t:s0:c143,c877
  tcontext=unconfined_u:object_r:user_home_t:s0
  tclass=file permissive=0
```

Interpretation:

| Field | Meaning |
|---|---|
| `denied { read }` | The attempted operation was a read |
| `comm="python"` | The gunicorn worker process |
| `scontext=...container_t...` | Source (subject) context |
| `tcontext=...user_home_t...` | Target (object) context |
| `tclass=file` | Target object class |
| `permissive=0` | SELinux enforced the denial (not Permissive) |

This is the key evidence that SELinux — not DAC and not a Docker flag — blocked
the operation.

#### 4.6 The permitted operation with `:Z`

```bash
./scripts/run.sh
curl -sS -w '\nHTTP %{http_code}\n' \
  --get --data-urlencode 'file=sample.txt' \
  http://127.0.0.1:5000/process
```

Observed:

```json
{"character_count":733,"file":"sample.txt","service":"cie-worker",
 "size_bytes":733,"status":"ok","word_count":114}
HTTP 200
```

Labels after `:Z`:

```text
system_u:object_r:container_file_t:s0:c191,c948 data
```

Inside the container:

```text
$ docker exec --user 10001:10001 cie-worker cat /proc/self/attr/current
system_u:system_r:container_t:s0:c191,c948
```

#### 4.7 Restricted operations (all safe and controlled)

```bash
# Write to the read-only input mount (Docker configuration)
docker exec --user 10001:10001 cie-worker touch /data/evil.txt
# touch: cannot touch '/data/evil.txt': Read-only file system

# Write to the read-only root filesystem (Docker configuration)
docker exec --user 10001:10001 cie-worker sh -c 'echo x > /etc/evil.txt'
# cannot create /etc/evil.txt: Read-only file system

# Read a protected host-style file as the non-root user (DAC)
docker exec --user 10001:10001 cie-worker cat /etc/shadow
# cat: /etc/shadow: Permission denied

# Capabilities are empty
docker exec --user 10001:10001 cie-worker grep -E '^Cap(Eff|Bnd)' /proc/self/status
# CapEff: 0000000000000000
# CapBnd: 0000000000000000
```

No real system file is modified. The write targets are a read-only mount, a
read-only rootfs and a path that does not exist; all are safe.

#### 4.8 The multiple-`:Z` lesson

`:Z` is **private**. If two containers use `:Z` on the same host directory, the
second start relabels the directory to its own MCS pair and the first container
loses access. This was observed during the lab: a second `:Z` container made the
running worker return 403 until the worker was restarted with its own `:Z`
label. Correct options:

* one dedicated host directory per container;
* `:z` for genuinely shared content;
* restart the affected container after relabelling.

#### 4.9 Restore the host label after the lab

```bash
sudo restorecon -F -Rv data
ls -Zd data      # back to user_home_t
```

> `-F` is required after Docker `:Z` in this environment. Without it,
> `restorecon` reports the Docker label as "customized by admin" and leaves it
> in place. `-F` forces the policy default (`user_home_t`). The demo script's
> `chcon` fallback achieves the same reset for this user-owned lab directory.

Only restore labels on this lab directory, never blindly on `/etc`, `/usr` or
other system paths.

#### 4.10 No custom SELinux policy

The standard container policy already permits `container_t` to read
`container_file_t` when the MCS categories match. Correct labelling is the
supported solution. Writing a custom policy would weaken or complicate the
standard confinement and is not required.

---

### Phase 5 — Inspection and troubleshooting

#### 5.1 Container inspection

```bash
docker ps -a --filter name=cie-worker
docker inspect cie-worker | jq '.[0] | {
  State: {Status: .State.Status, ExitCode: .State.ExitCode, Health: .State.Health.Status},
  User: .Config.User,
  ReadonlyRootfs: .HostConfig.ReadonlyRootfs,
  CapDrop: .HostConfig.CapDrop,
  SecurityOpt: .HostConfig.SecurityOpt,
  Privileged: .HostConfig.Privileged,
  NetworkMode: .HostConfig.NetworkMode,
  Mounts: [.Mounts[] | {Type, Source, Destination, Mode, RW}]
}'
```

Observed:

```text
NAMES        STATUS                    PORTS
cie-worker   Up 5 minutes (healthy)    127.0.0.1:5000->5000/tcp
```

```json
{
  "State": {"Status": "running", "ExitCode": 0, "Health": "healthy"},
  "User": "10001:10001",
  "ReadonlyRootfs": true,
  "CapDrop": ["ALL"],
  "SecurityOpt": ["no-new-privileges:true"],
  "Privileged": false,
  "NetworkMode": "cie-net",
  "Mounts": [
    {"Type": "bind", "Source": "/home/anique/DevOps_LabExam/cie/data",
     "Destination": "/data", "Mode": "ro,Z", "RW": false}
  ]
}
```

#### 5.2 Logs

```bash
docker logs --tail 20 cie-worker
```

Observed:

```text
[INFO] Starting gunicorn 23.0.0
[INFO] Listening at: http://0.0.0.0:5000
[INFO] Booting worker with pid: 7
[INFO] Booting worker with pid: 8
INFO cie-worker Processed file=sample.txt words=114 bytes=733
"GET /process?file=sample.txt HTTP/1.1" 200
WARNING cie-worker Permission denied resolving sample.txt
"GET /process?file=sample.txt HTTP/1.1" 403
```

#### 5.3 Exit status

```bash
docker inspect cie-worker --format 'Status={{.State.Status}} ExitCode={{.State.ExitCode}}'
```

For a running healthy worker: `Status=running ExitCode=0`.

To demonstrate a non-zero exit, run a controlled denied read without `:Z` and
without `--rm`:

```bash
docker run --name cie-denied-read \
  --user 10001:10001 --read-only --cap-drop ALL \
  -v "$PWD/data:/data:ro" cie-worker:1.0 \
  python -c "open('/data/sample.txt').read()"
# PermissionError ... ; exit status 1

docker ps -a --filter name=cie-denied-read
# cie-denied-read   Exited (1) ...

docker inspect cie-denied-read --format 'Status={{.State.Status}} ExitCode={{.State.ExitCode}}'
# Status=exited ExitCode=1

docker rm -f cie-denied-read
```

#### 5.4 Failure scenario 1 — incorrect mount target

**Initial failure.** The worker expects `/data`, but the volume is mounted at
`/data-input`:

```bash
docker run -d --name cie-badmount \
  --user 10001:10001 --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=16m \
  --cap-drop ALL --security-opt no-new-privileges:true \
  -p 127.0.0.1:5002:5000 \
  -v "$PWD/data:/data-input:ro,Z" \
  -e INPUT_DIR=/data \
  cie-worker:1.0

curl -sS -w '\nHTTP %{http_code}\n' http://127.0.0.1:5002/health
curl -sS -w '\nHTTP %{http_code}\n' \
  --get --data-urlencode 'file=sample.txt' http://127.0.0.1:5002/process
```

Observed:

```text
{"input_dir":"/data","input_dir_exists":false,"input_dir_readable":false,
 "service":"cie-worker","status":"degraded"}
HTTP 503

{"details":{"input_dir":"/data"},
 "error":{"code":"input_directory_unavailable",
          "message":"The configured input directory is not available inside the container."},
 "status":"error"}
HTTP 500
```

Logs:

```text
ERROR cie-worker Input directory is unavailable: /data
"GET /process?file=sample.txt HTTP/1.1" 500
```

Inspect:

```bash
docker inspect cie-badmount --format \
  'mounts={{range .Mounts}}{{.Source}}->{{.Destination}} {{end}}'
# mounts=/home/anique/DevOps_LabExam/cie/data->/data-input
```

**Diagnosis.** `/health` reports `input_dir_exists:false`; the mount
destination is `/data-input`, but `INPUT_DIR` is `/data`. This is a
configuration/mount mismatch, not SELinux: the source is correctly labelled
and `/data` simply does not exist.

**Root cause.** Wrong bind-mount target path.

**Correction.** Remove the bad container and use the normal script, which
mounts at `/data`:

```bash
docker rm -f cie-badmount
./scripts/run.sh
curl -sS 'http://127.0.0.1:5000/process?file=sample.txt'
# HTTP 200, word_count 114
```

**Verification.** `docker inspect cie-worker` shows
`"Destination": "/data"`; `/health` is 200; `/process` returns 114.
SELinux is still Enforcing.

#### 5.5 Failure scenario 2 — unsuitable Linux permissions (DAC)

**Initial failure.** The mount is correct and labelled, but the host directory
is `0700`, owned by UID 1000. The worker is UID 10001 and cannot traverse it.

```bash
chmod 700 data
curl -sS -w '\nHTTP %{http_code}\n' http://127.0.0.1:5000/health
curl -sS -w '\nHTTP %{http_code}\n' \
  --get --data-urlencode 'file=sample.txt' http://127.0.0.1:5000/process
```

Observed:

```text
{"input_dir":"/data","input_dir_exists":true,"input_dir_readable":false,...}
HTTP 503

{"error":{"code":"file_inaccessible",
          "message":"The worker is not permitted to read this file."},"status":"error"}
HTTP 403
```

Check for an AVC:

```bash
journalctl --since "2 min ago" | grep -i 'avc.*name="data"'
# no output
```

**Diagnosis.** `stat` shows `drwx------ anique:anique data`; the label is
correct (`container_file_t`). There is no AVC, so this is DAC, not SELinux.

**Root cause.** Directory mode `0700` denies traversal to UID 10001.

**Correction.**

```bash
chmod 755 data
chmod 644 data/sample.txt
```

**Verification.**

```bash
curl -sS -w '\nHTTP %{http_code}\n' \
  --get --data-urlencode 'file=sample.txt' http://127.0.0.1:5000/process
# HTTP 200, word_count 114
getenforce
# Enforcing
```

The correction changes only DAC permissions; the SELinux label, read-only
mount, dropped capabilities and non-root user remain in place.

#### 5.6 Failure scenario 3 — SELinux label missing

This is the no-`:Z` case from Phase 4. Summary:

| Step | Observation |
|---|---|
| Initial failure | API 503/403, direct read `PermissionError` |
| Diagnosis | `ls -Zd data` shows `user_home_t`; AVC `denied { read }` |
| Root cause | `container_t` cannot read `user_home_t`; no private MCS pair |
| Correction | Mount with `:Z` (or `:z` for shared data) |
| Verification | `ls -Zd data` shows `container_file_t:s0:cX,cY`; API 200 |
| Security remains | SELinux Enforcing; read-only mount; non-root; caps dropped |

#### 5.7 Security inspection script

```bash
./scripts/inspect.sh
```

It prints SELinux mode, data label, container state, `docker inspect` security
fields, process context, capabilities, logs and network details.

---

### Phase 6 — Kubernetes / Minikube

#### What we are doing

Deploy the same image to Minikube with:

* a `Deployment` (one replica, hardened `securityContext`);
* a `ConfigMap` containing `sample.txt` mounted read-only at `/data`;
* a `ClusterIP` `Service` on port 80 targeting container port 5000.

#### Why

Kubernetes provides declarative deployment, health management and service
discovery. ClusterIP keeps the worker internal; `kubectl port-forward` gives a
controlled local path for testing without exposing a NodePort or LoadBalancer.

#### Manifests

`kubernetes/namespace.yaml` — namespace `cie`.

`kubernetes/configmap.yaml` — the sample text as a ConfigMap key:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cie-input
  namespace: cie
data:
  sample.txt: |
    ...
```

If `data/sample.txt` changes, regenerate the ConfigMap so the two do not
drift:

```bash
kubectl create configmap cie-input -n cie \
  --from-file=data/sample.txt \
  --dry-run=client -o yaml > kubernetes/configmap.yaml
kubectl apply -f kubernetes/configmap.yaml
```

`kubernetes/deployment.yaml` — key security fields:

```yaml
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    fsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: worker
      image: cie-worker:1.0
      imagePullPolicy: Never
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - {name: input-data, mountPath: /data, readOnly: true}
        - {name: tmp, mountPath: /tmp}
```

`kubernetes/service.yaml`:

```yaml
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: cie-worker
  ports:
    - name: http
      port: 80
      targetPort: http
```

`targetPort: http` refers to the container port named `http` (5000), so the
Service port (80) and container port (5000) are clearly separated.

#### Start Minikube and load the image

```bash
minikube start --driver=docker --cpus=2 --memory=4096
minikube image load cie-worker:1.0
```

`imagePullPolicy: Never` means the Pod will not try a registry. This matters
because the image is local and there is no registry push in this lab. If you
later push to a registry, change the policy to `IfNotPresent` and the image
reference accordingly.

#### Apply

```bash
kubectl apply -f kubernetes/namespace.yaml
kubectl apply \
  -f kubernetes/configmap.yaml \
  -f kubernetes/deployment.yaml \
  -f kubernetes/service.yaml

kubectl -n cie rollout status deployment/cie-worker --timeout=180s
kubectl -n cie get pods -o wide
kubectl -n cie get svc
```

> Apply the namespace **first**. A single `kubectl apply -f kubernetes/` can
> process `configmap.yaml`/`deployment.yaml` before `namespace.yaml` and fail
> with `namespaces "cie" not found`. This was observed and is why the script
> applies the namespace separately.

Observed:

```text
deployment "cie-worker" successfully rolled out

NAME                          READY   STATUS    RESTARTS   AGE   IP           NODE
cie-worker-5dbf7dd665-j4jxh   1/1     Running   0          6s    10.244.0.4   minikube

NAME         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
cie-worker   ClusterIP   10.104.143.47   <none>        80/TCP    26s
```

#### Access with port-forward

```bash
kubectl -n cie port-forward svc/cie-worker 8080:80
```

Second terminal:

```bash
curl -s http://127.0.0.1:8080/health | jq .
curl -s 'http://127.0.0.1:8080/process?file=sample.txt' | jq .
BASE_URL=http://127.0.0.1:8080 ./scripts/test.sh
```

Observed:

```json
{"input_dir":"/data","input_dir_exists":true,"input_dir_readable":true,
 "service":"cie-worker","status":"ok"}
```

```json
{"character_count":733,"file":"sample.txt","service":"cie-worker",
 "size_bytes":733,"status":"ok","word_count":114}
```

The full suite reported `PASS: 18 FAIL: 0`.

#### Verify pod security

```bash
POD=$(kubectl -n cie get pod -l app.kubernetes.io/name=cie-worker -o jsonpath='{.items[0].metadata.name}')
kubectl -n cie exec "$POD" -- sh -c 'id; grep -E "^Cap(Eff|Bnd)" /proc/self/status'
kubectl -n cie exec "$POD" -- sh -c 'touch /data/x'   # Read-only file system
kubectl -n cie exec "$POD" -- sh -c 'touch /etc/x'    # Read-only file system
kubectl -n cie exec "$POD" -- cat /etc/shadow          # Permission denied
```

Observed:

```text
uid=10001(app) gid=10001(app) groups=10001(app)
CapEff: 0000000000000000
CapBnd: 0000000000000000
touch: cannot touch '/data/x': Read-only file system
touch: cannot touch '/etc/x': Read-only file system
cat: /etc/shadow: Permission denied
```

#### SELinux inside Minikube — important distinction

Host SELinux remains Enforcing. The Minikube node runs as a Docker container
under the host's SELinux policy with the privileged container type `spc_t`.
However, the Pods inside it are **not** individually SELinux-confined in this
setup:

```bash
minikube ssh -- getenforce
# bash: getenforce: command not found

minikube ssh -- cat /proc/self/attr/current
# system_u:system_r:spc_t:s0

minikube ssh -- sudo grep -i enable_selinux /etc/containerd/config.toml
# enable_selinux = false
```

Inside the Pod:

```text
$ kubectl -n cie exec "$POD" -- cat /proc/self/attr/current
system_u:system_r:spc_t:s0
```

Therefore:

* Host Docker `:Z` labels do **not** automatically apply to Kubernetes
  volumes.
* The Kubernetes input is a ConfigMap volume managed by the kubelet, not a
  host bind mount.
* The Pod is secured by `runAsNonRoot`, fixed UID/GID, `allowPrivilegeEscalation:
  false`, `capabilities.drop: ALL`, `readOnlyRootFilesystem: true`, a read-only
  ConfigMap volume, `seccompProfile: RuntimeDefault`, and ClusterIP-only
  exposure.
* Do not claim that SELinux blocked a Pod operation in this Minikube
  configuration.

#### Kubernetes failure and recovery (mount/config mismatch)

Introduce a wrong input path without changing the manifest:

```bash
kubectl -n cie set env deployment/cie-worker INPUT_DIR=/data-wrong
sleep 12
kubectl -n cie get pods
kubectl -n cie rollout status deployment/cie-worker --timeout=20s
kubectl -n cie logs -l app.kubernetes.io/name=cie-worker --tail=8 --prefix
```

Observed:

```text
NAME                          READY   STATUS    RESTARTS   AGE
cie-worker-5dbf7dd665-j4jxh   1/1     Running   0          68s
cie-worker-8574b8775c-p458w   0/1     Running   0          12s

Waiting for deployment "cie-worker" rollout to finish: 1 old replicas are pending termination...
error: timed out waiting for the condition
```

The new Pod logs:

```text
GET /health HTTP/1.1" 503 123 "-" "kube-probe/1.37"
```

`kubectl describe pod` shows:

```text
Environment:
  INPUT_DIR:  /data-wrong
Mounts:
  /data from input-data (ro)
```

**Diagnosis.** The volume is mounted at `/data`, but the app is told to read
`/data-wrong`; `/health` returns 503, readiness fails, and the new Pod never
becomes Ready. The old Pod keeps serving during the rollout.

**Correction.**

```bash
kubectl -n cie set env deployment/cie-worker INPUT_DIR=/data
kubectl -n cie rollout status deployment/cie-worker --timeout=180s
kubectl -n cie get pods
```

**Verification.** New Pod becomes `1/1 Running`; port-forward `/process`
returns 200 with `word_count: 114`. The securityContext was never weakened.

#### Common Kubernetes errors

| Symptom | Cause | Fix |
|---|---|---|
| `namespaces "cie" not found` | Applied workload before namespace | Apply `namespace.yaml` first |
| `ErrImageNeverPull` / `ImagePullBackOff` | Image not loaded into Minikube | `minikube image load cie-worker:1.0` |
| `0/1 Running`, readiness 503 | Wrong `INPUT_DIR`, missing ConfigMap key, bad mount | Check `describe`, logs, env, mount |
| `CrashLoopBackOff` | App crash or bad command | `kubectl logs --previous` |
| `port-forward` address in use | Port 8080 already bound | Use another local port |
| Rollout stuck | New Pod never Ready | Inspect events and probes |

#### Cleanup

```bash
kubectl -n cie delete -f kubernetes/configmap.yaml \
  -f kubernetes/deployment.yaml -f kubernetes/service.yaml
kubectl delete -f kubernetes/namespace.yaml
# or keep the deployment for the demonstration
minikube stop
```

---

### Phase 7 — End-to-end verification

Run the following in order. Expected results are shown.

#### 7.1 Docker

```bash
cd /home/anique/DevOps_LabExam/cie

./scripts/build.sh
./scripts/run.sh
./scripts/test.sh
```

Expected: image builds, worker healthy, `PASS: 18 FAIL: 0`.

#### 7.2 Manual API checks

```bash
curl -s http://127.0.0.1:5000/health | jq .
curl -s 'http://127.0.0.1:5000/process?file=sample.txt' | jq .
curl -s -o /dev/null -w '%{http_code}\n' \
  --get --data-urlencode 'file=../etc/passwd' \
  http://127.0.0.1:5000/process
```

Expected: health 200; word count 114; traversal 400.

#### 7.3 SELinux

```bash
getenforce
./scripts/selinux-demo.sh
journalctl --since "15 min ago" | grep -i 'avc.*container_t'
```

Expected: `Enforcing`; a denied read; AVC with `permissive=0`; then a permitted
200 response after `:Z`.

#### 7.4 Restricted operations

```bash
docker exec --user 10001:10001 cie-worker touch /data/evil.txt
docker exec --user 10001:10001 cie-worker touch /etc/evil.txt
docker exec --user 10001:10001 cie-worker cat /etc/shadow
```

Expected: two `Read-only file system` errors and one `Permission denied`.

#### 7.5 Inspection

```bash
./scripts/inspect.sh
```

Expected: `User=10001:10001`, `ReadonlyRootfs=true`, `CapDrop=["ALL"]`,
`SecurityOpt=["no-new-privileges:true"]`, `Privileged=false`, mount `ro,Z`,
process context `container_t`.

#### 7.6 Troubleshooting

Follow [5.4](#54-failure-scenario-1--incorrect-mount-target) and
[5.5](#55-failure-scenario-2--unsuitable-linux-permissions-dac), or run the
equivalent manual commands. Expected: 503/403 during the fault, 200 after the
correction, `getenforce` still `Enforcing`.

#### 7.7 Kubernetes

```bash
./scripts/k8s-deploy.sh
kubectl -n cie get pods,svc
kubectl -n cie port-forward svc/cie-worker 8080:80
# second terminal:
BASE_URL=http://127.0.0.1:8080 ./scripts/test.sh
```

Expected: `1/1 Running`, `ClusterIP`, `PASS: 18 FAIL: 0`.

#### 7.8 Test matrix

| # | Test | Expected |
|---|---|---|
| 1 | `GET /health` | 200, `status:ok` |
| 2 | `GET /process?file=sample.txt` | 200, `word_count:114` |
| 3 | `wc -w data/sample.txt` | 114 |
| 4 | `file=../etc/passwd` | 400, `invalid_filename` |
| 5 | `file=/etc/passwd` | 400, `invalid_filename` |
| 6 | `file=..%2F..%2Fetc%2Fpasswd` | 400 |
| 7 | `file=.` | 400 |
| 8 | `file=missing.txt` | 404, `file_not_found` |
| 9 | no `file` parameter | 400, `missing_file_parameter` |
| 10 | unknown endpoint | 404, `not_found` |
| 11 | `POST /process` | 405 |
| 12 | write `/data` | `Read-only file system` |
| 13 | write `/etc` | `Read-only file system` |
| 14 | read `/etc/shadow` as 10001 | `Permission denied` |
| 15 | no `:Z` read | SELinux AVC, API 503/403 |
| 16 | with `:Z` read | 200, word count 114 |
| 17 | Docker inspect | non-root, RO rootfs, caps dropped, ro,Z mount |
| 18 | Minikube Pod | 1/1 Running, ClusterIP, 18/18 tests |

---

## E. SELinux deep dive

### E.1 What mandatory access control means

Discretionary Access Control (DAC) is the normal Unix permission model: the
owner of a file decides who may read/write/execute it (`chmod`, ACLs). A
process running as the owner can change those permissions. DAC is
**discretionary**.

Mandatory Access Control (MAC) adds a system-wide policy that even the file
owner cannot override. Every process and object gets a security label, and the
kernel checks the policy on each access. `chmod 777` does not bypass MAC.

### E.2 What SELinux is

SELinux is a Linux Security Module implementing MAC. Fedora ships a `targeted`
policy: most user processes run in `unconfined_t`, while network-facing and
container processes run in confined domains such as `container_t`. Confined
domains can only perform the operations the policy allows, regardless of Unix
permissions.

### E.3 SELinux modes

| Mode | Behaviour | Use |
|---|---|---|
| Enforcing | Policy is enforced; denied operations fail and produce AVCs | Required for this lab |
| Permissive | Denials are logged but allowed | Debugging only; not used here |
| Disabled | SELinux is off | Never used here |

Check:

```bash
getenforce
sestatus
```

Changing mode temporarily (`setenforce 0`) would weaken security and invalidate
the demonstration. The lab keeps Enforcing throughout.

### E.4 SELinux contexts

A context has four fields:

```text
user:role:type:level
```

Example:

```text
system_u:object_r:container_file_t:s0:c191,c948
```

| Field | Example | Meaning |
|---|---|---|
| User | `system_u` | SELinux user identity |
| Role | `object_r` | Role for file objects (`system_r` for processes) |
| Type | `container_file_t` | The main type-enforcement label |
| Level | `s0:cX,cY` | MLS sensitivity plus MCS categories (values vary) |

Type enforcement decides most access. MCS (Multi-Category Security) adds
categories used to isolate containers from each other even when they share the
same type.

### E.5 How Docker interacts with SELinux

Docker is started with `--selinux-enabled` (observed in the service command).
When a container starts, Docker assigns:

* the container process the `container_t` type and a unique MCS pair;
* a matching category to volumes that use `:Z`.

The bind mount then has a context such as:

```text
system_u:object_r:container_file_t:s0:c191,c948
```

and the process has:

```text
system_u:system_r:container_t:s0:c191,c948
```

Because type and categories match, the read is allowed. Without `:Z`, the host
file keeps `user_home_t` and the categories do not match, so `container_t` is
denied.

### E.6 What `:Z` and `:z` mean

* `:Z` — private, unshared. Docker relabels the source with
  `container_file_t` and a unique MCS pair. Only that container (and containers
  sharing the same pair) can access it.
* `:z` — shared. Docker applies a shared label so multiple containers can use
  the content. Less isolation.
* Neither — Docker leaves the host label alone. The operation works only if the
  existing label is already permitted.

This lab uses `:Z` because one worker owns the input directory.

### E.7 Why container access to host files can be denied

Common causes, in order of likelihood:

1. **Missing/incorrect SELinux label** — host file is `user_home_t`; container
   is `container_t`. Fix with `:Z`/`:z` or a correct persistent context.
2. **MCS mismatch** — another `:Z` container relabelled the directory; the
   first container's category no longer matches. Use one directory per
   container, `:z`, or restart the container.
3. **DAC permissions** — directory not traversable or file not readable by the
   container UID. Fix with `chmod`/ownership, not by disabling SELinux.
4. **Docker mount options** — `ro` mount, missing mount, wrong target path.
5. **Custom policy** — an unusual type transition; not the case here.

### E.8 How to inspect AVC denials

```bash
# Current mode
getenforce

# Recent denials via auditd (root)
sudo ausearch -m AVC -ts recent
sudo ausearch -m AVC -ts recent -c python

# Same records via journald (works for the logged-in user here)
journalctl --since "15 min ago" | grep -i 'avc.*container_t'

# Human-readable summary if setroubleshoot is installed
sudo sealert -a /var/log/audit/audit.log
```

An AVC record contains:

```text
avc: denied { read } for pid=... comm="python" name="sample.txt"
scontext=system_u:system_r:container_t:s0:c143,c877
tcontext=unconfined_u:object_r:user_home_t:s0
tclass=file permissive=0
```

`permissive=0` confirms enforcement. If `permissive=1`, the operation was only
logged (Permissive mode), which would not be acceptable evidence of blocking.

### E.9 Troubleshooting labels and permissions

Decision procedure:

1. `getenforce` — is SELinux Enforcing?
2. `ls -Zd <path>` — what is the host label?
3. `docker exec ... cat /proc/self/attr/current` — what is the process label?
4. Try the operation; does it fail with `EACCES`/`EPERM`?
5. Check for an AVC at the same time.
6. If there is an AVC, it is SELinux. Fix labels (`:Z`, `:z`,
   `restorecon`), not DAC.
7. If there is no AVC, check DAC (`stat`, `namei -l`), mount options, and
   container configuration.
8. Re-test after each single change.

Do not:

* run `chmod 777` and assume it fixed SELinux;
* use `--privileged` or `--security-opt label=disable`;
* switch to Permissive;
* apply `chcon`/`restorecon` to system directories.

### E.10 SELinux vs AppArmor

| Aspect | SELinux | AppArmor |
|---|---|---|
| Model | Type enforcement + MLS/MCS, label-based | Path-based profiles |
| Default on | Fedora, RHEL, CentOS | Ubuntu, SUSE |
| Labels | Every process/object has a context | Profiles attach to executables |
| Granularity | Very fine, including categories | Simpler path rules |
| Tools | `sestatus`, `ls -Z`, `ausearch`, `semanage`, `restorecon` | `aa-status`, `apparmor_parser` |
| This lab | Used | Not installed/used |

Fedora's supported, preinstalled MAC is SELinux. Installing AppArmor would be
an unnecessary, unsupported change and would not demonstrate Fedora's actual
security model.

### E.11 Why SELinux is appropriate for this Fedora implementation

* It is already enabled and enforcing on Fedora.
* The container policy (`container_t`, `container_file_t`) is maintained by the
  distribution.
* Docker has first-class `:Z`/`:z` support.
* Audit tools are available.
* It demonstrates real MAC, not just DAC or Docker flags.

### E.12 Practical examples from this experiment

| Scenario | Label | Result |
|---|---|---|
| Host file before mount | `user_home_t` | Container cannot read |
| Bind mount without `:Z` | `user_home_t` | AVC denied; API 503/403 |
| Bind mount with `:Z` | `container_file_t:s0:cX,cY` | API 200; word count 114 |
| Second `:Z` container on same dir | new MCS pair | First container loses access until restarted |
| After `restorecon` | `user_home_t` | Host label restored; container must be restarted with `:Z` |

### E.13 Common misconceptions

| Misconception | Reality |
|---|---|
| "SELinux is off on Fedora" | Fedora Workstation commonly runs Enforcing; check `getenforce`. |
| "`chmod 777` fixes permission denied" | It cannot override SELinux type/MCS rules. |
| "`--privileged` is a valid fix" | It removes the controls the lab is demonstrating. |
| "AppArmor is the same as SELinux" | Different models and tooling; Fedora uses SELinux. |
| "Any permission denied is SELinux" | Check for an AVC; DAC and Docker `ro` mounts also deny. |
| "`:Z` and `:z` are identical" | `:Z` is private; `:z` is shared. |
| "Kubernetes pods inherit host `:Z` labels" | Not automatically; this Minikube containerd has SELinux disabled. |

---

## F. Docker deep dive

### F.1 Images versus containers

* An **image** is an immutable, layered filesystem plus metadata (command,
  environment, user). `cie-worker:1.0` is an image.
* A **container** is a running instance of an image with a writable layer,
  namespaces, cgroups and security settings. `cie-worker` is a container.
* Many containers can run from one image; rebuilding the image does not change
  running containers until they are recreated.

### F.2 Dockerfile instructions used

| Instruction | Purpose |
|---|---|
| `FROM` | Base image |
| `ENV` | Runtime defaults (`INPUT_DIR`, unbuffered logs) |
| `RUN` | Create user, install dependencies, fix ownership |
| `WORKDIR` | Set `/app` |
| `COPY` | Add requirements and app code |
| `USER` | Switch to UID 10001 |
| `EXPOSE` | Document container port 5000 |
| `HEALTHCHECK` | Mark unhealthy if `/health` fails |
| `CMD` | gunicorn command |

### F.3 Port mapping

```bash
-p 127.0.0.1:5000:5000
```

* host interface: `127.0.0.1` (loopback only)
* host port: `5000`
* container port: `5000`

`EXPOSE 5000` does not publish anything; it is documentation. In Kubernetes,
the Service maps port 80 to the named container port `http` (5000), and
`kubectl port-forward` creates the local tunnel.

### F.4 Bind mounts versus volumes

| | Bind mount | Named volume |
|---|---|---|
| Source | Host path | Docker-managed storage |
| Use | Supply existing input files | Persist data managed by Docker |
| SELinux | `:Z`/`:z` often needed | Docker labels the volume automatically |
| This lab | `data/` mounted at `/data` | Not used |

A bind mount is correct here because the input files live in the project and
must not be copied into the image.

### F.5 Custom bridge networks

A user-defined bridge gives isolation from the default bridge and embedded DNS.
Containers on `cie-net` can resolve each other by name. The worker publishes
only loopback on the host, so the network is the internal path.

### F.6 Non-root containers

The image creates UID/GID 10001 and uses `USER 10001:10001`. Benefits:

* a compromised process does not have root's DAC override;
* `CAP_DAC_OVERRIDE` is unavailable (and all capabilities are dropped);
* file ownership in the image is root, so the app cannot modify its own code;
* Kubernetes can enforce the same UID with `runAsNonRoot`.

### F.7 Container inspection and logs

```bash
docker ps -a
docker inspect cie-worker
docker logs -f cie-worker
docker stats cie-worker
docker top cie-worker
```

Use `docker inspect` for configuration (user, mounts, security options, state,
health) and `docker logs` for application behaviour. Logs are on stdout/stderr
because gunicorn is started with `--access-logfile - --error-logfile -`.

### F.8 Security options in this lab

| Option | Effect |
|---|---|
| `--read-only` | Root filesystem is immutable |
| `--tmpfs /tmp:rw,noexec,nosuid,size=16m` | Minimal writable scratch space |
| `--cap-drop ALL` | Empty capability sets |
| `--security-opt no-new-privileges:true` | No privilege gain via setuid |
| `--user 10001:10001` | Non-root |
| `-v ...:ro,Z` | Read-only + private SELinux label |
| `-p 127.0.0.1:...` | Loopback-only publication |
| `--network cie-net` | Isolated bridge with DNS |

Seccomp: Docker's default seccomp profile is applied automatically
(`name=seccomp,profile=builtin`). No custom profile is needed for this lab.

---

## G. Kubernetes / Minikube deep dive

### G.1 Pods

A Pod is the smallest deployable unit: one or more containers sharing a network
namespace and volumes. This lab uses one container per Pod.

### G.2 Deployments

A Deployment manages ReplicaSets and Pods, provides rolling updates and
self-healing. `replicas: 1` is enough for the lab. The Deployment owns the Pod
template; changing the template creates a new ReplicaSet.

### G.3 Services and ClusterIP

A Service gives a stable virtual IP and DNS name to a set of Pods selected by
labels. `ClusterIP` is reachable only inside the cluster. This is the default
and the least-exposed option. Port 80 is the Service port; `targetPort: http`
maps to container port 5000.

### G.4 Port forwarding

```bash
kubectl -n cie port-forward svc/cie-worker 8080:80
```

kubectl opens a local listener on 127.0.0.1:8080 and tunnels through the API
server to the Service. It is a debugging/access aid, not an externally exposed
Service. Stop it with Ctrl-C.

### G.5 Loading an image into Minikube

```bash
minikube image load cie-worker:1.0
```

This imports the host Docker image into the Minikube node's containerd. The
Deployment uses `imagePullPolicy: Never` so Kubernetes never tries a registry.
Verify with:

```bash
minikube image ls | grep cie-worker
```

### G.6 Container security context

Pod-level:

```yaml
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
fsGroup: 10001
seccompProfile:
  type: RuntimeDefault
```

Container-level:

```yaml
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: ["ALL"]
```

Observed effective values matched the manifest. `fsGroup: 10001` helps with
volume group ownership; the ConfigMap files are `0444` and readable.

### G.7 ConfigMap volume versus host bind mount

| Docker lab | Kubernetes lab |
|---|---|
| Host path `data/` | ConfigMap `cie-input` |
| Bind mount with `:Z` | Kubelet-managed volume |
| SELinux `container_file_t` + MCS | No host `:Z`; SELinux disabled in Minikube containerd |
| `-v ...:ro,Z` | `configMap` volume + `readOnly: true` |

A ConfigMap is appropriate for small, declarative sample data. A real
deployment with large or changing documents would use a PersistentVolume and
an appropriate StorageClass; that is outside this lab's scope.

### G.8 Health checks

`/health` returns 503 when `/data` is missing or unreadable. The readiness
probe uses it, so a broken mount keeps the Pod out of the Service endpoints.
The liveness probe restarts a stuck container. This is exactly what the
Kubernetes failure demonstration shows: the new Pod stays `0/1` and the old
Pod continues serving.

### G.9 SELinux in Minikube

As shown in Phase 6, the Minikube node's containerd has `enable_selinux =
false`, and the pod process reports `spc_t`. Host SELinux labels the Minikube
node container itself as the privileged `spc_t` type; it does not provide
per-pod file-label enforcement. The Kubernetes phase therefore demonstrates
securityContext and least privilege, not SELinux AVCs. This distinction must be
stated clearly in the viva.

### G.10 How the app is deployed and accessed

1. Build the image on the host.
2. Start Minikube (docker driver).
3. `minikube image load`.
4. Apply namespace, ConfigMap, Deployment, Service.
5. Kubelet mounts the ConfigMap at `/data` read-only.
6. Readiness checks `/health`.
7. Service selects the Pod on port 5000.
8. `kubectl port-forward` provides local access on 8080.

---

## H. Troubleshooting

### H.1 Diagnostic decision tree

```text
Request fails
│
├─ /health returns 503
│   ├─ input_dir_exists=false  -> wrong mount target / missing volume
│   └─ input_dir_exists=true, readable=false
│       ├─ AVC present         -> SELinux label/MCS mismatch
│       └─ no AVC              -> DAC permissions or ownership
│
├─ /process returns 403
│   ├─ AVC present             -> SELinux
│   └─ no AVC                  -> DAC (mode/owner) or file unreadable
│
├─ /process returns 404
│   └─ file really absent, or wrong directory mounted
│
├─ /process returns 400
│   └─ validation rejected the filename (expected for traversal)
│
├─ /process returns 500 input_directory_unavailable
│   └─ INPUT_DIR does not exist in the container
│
└─ Container exits non-zero
    ├─ inspect ExitCode + logs
    ├─ permission denied -> check labels/DAC
    └─ app crash -> check gunicorn/Flask logs
```

### H.2 Consolidated error table

| Symptom | Likely cause | Check | Fix |
|---|---|---|---|
| `Permission denied` on `/data` | SELinux label missing | `ls -Zd data`, `journalctl ... avc` | Add `:Z`; restart container |
| `Permission denied` on `/data`, no AVC | DAC mode/owner | `stat -c '%A %U:%G' data` | `chmod 755`, correct owner |
| `Read-only file system` on `/data` | `ro` bind mount | `docker inspect` mount | Expected; do not write input |
| `Read-only file system` on `/etc` | `--read-only` rootfs | `docker inspect` | Expected |
| 503 health, `exists:false` | wrong mount target | `docker inspect` mounts | mount at `/data` |
| 503 health, `readable:false`, AVC | SELinux type/MCS | AVC | `:Z`/`:z`, restart |
| 403 process | SELinux or DAC | AVC + `stat` | label or chmod |
| 500 `input_directory_unavailable` | `INPUT_DIR` wrong | health JSON | set `INPUT_DIR=/data` |
| 404 `file_not_found` | missing file | `ls data` | use existing name |
| 400 `invalid_filename` | traversal/absolute path | request | use plain basename |
| `port already allocated` | host port in use | `ss -ltnp` | `PORT=5001 ./scripts/run.sh` |
| Pod `ImagePullBackOff` | image not loaded | `minikube image ls` | `minikube image load` |
| Pod `0/1`, readiness 503 | wrong env/mount | `describe`, logs | correct `INPUT_DIR`/mount |
| `namespaces "cie" not found` | apply order | `kubectl get ns` | apply namespace first |
| Rollout stuck | new Pod never Ready | `get pods`, `describe` | fix probe/config |

### H.3 The three failures in one table

| Failure | Evidence | Root cause | Correction | Security after |
|---|---|---|---|---|
| Wrong mount target | health `exists:false`; mount `/data-input` | Mount path mismatch | mount at `/data` | unchanged |
| DAC `0700` | 403, no AVC; `drwx------` | UID 10001 cannot traverse | `chmod 755` | unchanged |
| Missing `:Z` | 403, AVC `container_t -> user_home_t` | SELinux type/MCS mismatch | add `:Z` | unchanged |

### H.4 Confirming security was not weakened

After every correction:

```bash
getenforce
# Enforcing

docker inspect cie-worker --format \
  'user={{.Config.User}} ro={{.HostConfig.ReadonlyRootfs}} caps={{.HostConfig.CapDrop}} sec={{.HostConfig.SecurityOpt}}'

docker exec --user 10001:10001 cie-worker \
  grep -E '^Cap(Eff|Bnd)' /proc/self/status
# all zero

ls -Zd data
# container_file_t with an MCS pair (while the container is running)
```

The fixes were DAC/mount/label corrections, not `--privileged`, `setenforce 0`
or `label=disable`.

---

## I. Viva preparation

### 1. Why use Flask for this application?

Flask is a small, explicit Python web framework. Two routes (`/health` and
`/process`) and JSON responses are enough for the lab. It is easy to read,
test and explain, and it does not bring a database or ORM that the problem does
not need.

### 2. Why containerise the application?

Containers package the app and its exact dependencies, so it runs the same way
on any Docker host. They also provide the isolation and security controls used
here: non-root user, read-only rootfs, dropped capabilities, resource limits
and SELinux labels.

### 3. What is the difference between an image and a container?

An image is an immutable template (layers + metadata). A container is a running
instance of that image with a writable layer, namespaces, cgroups and runtime
security settings. You can run many containers from one image.

### 4. Why use a non-root Docker user?

If the process is compromised, it does not have root's DAC override or
capabilities. It cannot modify root-owned files, and `CAP_DAC_OVERRIDE` is
unavailable. This is least privilege and defence in depth.

### 5. What is a Docker bind mount?

A bind mount maps a host path directly into a container. Here `data/` is
mounted at `/data`. It lets input files live outside the image and be updated
without rebuilding. `:ro` makes it read-only; `:Z` gives it a private SELinux
label.

### 6. What is a Docker bridge network?

A bridge network is a virtual L2 network. A user-defined bridge (here
`cie-net`) isolates containers from the default bridge and provides embedded
DNS, so containers can reach each other by name.

### 7. Why does Fedora use SELinux instead of AppArmor?

SELinux is the MAC system integrated into Fedora/RHEL, with policy, tooling and
container support shipped by the distribution. AppArmor is path-based and is the
default on Ubuntu/SUSE. Using the platform's native MAC is correct and avoids
installing an unsupported second LSM.

### 8. What is mandatory access control?

MAC is a system-wide policy that constrains what every process may do, even if
the process owns the file or has Unix permissions. SELinux labels and policy
implement MAC; `chmod 777` cannot override it.

### 9. What is an SELinux context?

A label of the form `user:role:type:level`, for example
`system_u:object_r:container_file_t:s0:c191,c948`. The type is the main
enforcement field; the level/categories isolate containers.

### 10. What is the difference between `:Z` and `:z`?

`:Z` applies a private, unshared label with a unique MCS pair and is for one
container. `:z` applies a shared label and is for content used by multiple
containers. `:Z` gives stronger isolation.

### 11. What happens when SELinux denies access?

The kernel returns `EACCES`/`EPERM`, writes an AVC record (if auditing is on),
and the application sees `PermissionError`. In this lab `/process` maps that to
HTTP 403 and `/health` reports unreadable. The operation does not happen.

### 12. How do you identify an SELinux denial?

Check `getenforce`, reproduce the failure, then search the audit stream:

```bash
sudo ausearch -m AVC -ts recent
journalctl --since "15 min ago" | grep -i 'avc.*container_t'
```

Look for `denied`, the source context (`scontext`), target context
(`tcontext`), class and `permissive=0`.

### 13. What is the difference between SELinux and ordinary Linux permissions?

DAC (Unix permissions/ACLs) is based on owner/group/mode and can be changed by
the owner. SELinux is MAC: labels and policy are enforced by the kernel and
cannot be overridden by `chmod`. A file can be `0777` and still be denied by
SELinux.

### 14. What is a Kubernetes Pod?

The smallest deployable Kubernetes unit. It contains one or more containers
that share a network namespace and volumes. This lab uses a single-container
Pod.

### 15. What is a Deployment?

A controller that manages ReplicaSets and Pods, supports rolling updates,
scaling and self-healing. It ensures the desired number of Pods is running.

### 16. What is a ClusterIP Service?

The default Service type. It exposes a stable virtual IP and DNS name only
inside the cluster. It is not reachable from outside unless you add a
NodePort, LoadBalancer, Ingress or port-forward.

### 17. Why use Minikube?

Minikube runs a single-node Kubernetes cluster locally (here as a Docker
container). It is lightweight, reproducible and sufficient to demonstrate
Deployments, Services, probes and securityContext without a cloud cluster.

### 18. How do you debug a failing Pod?

```bash
kubectl -n cie get pods
kubectl -n cie describe pod <pod>
kubectl -n cie logs <pod>
kubectl -n cie logs <pod> --previous
kubectl -n cie get events --sort-by=.lastTimestamp
kubectl -n cie exec <pod> -- sh
```

Check image pull, readiness/liveness failures, environment, mounts, resource
limits and events.

### 19. How do you diagnose a failed file-processing request?

1. `GET /health` — is the input directory present and readable?
2. `docker logs` / `kubectl logs` — validation vs read error.
3. `docker inspect` — mount source, destination, `ro`, `Z`.
4. `ls -Zd data` — host SELinux label.
5. `journalctl ... avc` / `ausearch` — SELinux denial?
6. `stat`/`namei -l` — DAC permissions.
7. Correct one thing, re-test.

### 20. Why gunicorn instead of `flask run`?

The Flask development server is single-process, not designed for production and
prints warnings. gunicorn is a WSGI server with multiple workers and proper
access/error logs, and it runs well as PID 1 in a container.

### 21. Why a read-only root filesystem?

It prevents an attacker (or a bug) from modifying application code, writing
malware, or persisting changes in the container. Writable paths are explicitly
limited (here `/tmp` as a small `tmpfs`).

### 22. Why drop all capabilities?

Linux capabilities split root's powers into units such as `CAP_DAC_OVERRIDE`,
`CAP_NET_ADMIN` and `CAP_SYS_ADMIN`. The worker needs none of them. Dropping all
capabilities means even a root-esque bug cannot perform privileged operations.

### 23. What does `no-new-privileges` do?

It prevents a process from gaining additional privileges through setuid/setgid
binaries or file capabilities. It blocks a common escalation path inside a
container.

### 24. Why ClusterIP rather than NodePort or LoadBalancer?

The worker is an internal service. ClusterIP exposes it only inside the
cluster; `kubectl port-forward` gives controlled local access for the lab.
NodePort/LoadBalancer would unnecessarily expose it on the host/network.

### 25. Why a ConfigMap instead of a hostPath in Kubernetes?

A ConfigMap is declarative, portable and read-only, and does not depend on a
host path or host SELinux label. It is appropriate for the small sample file.
A hostPath would tie the Pod to a node and reintroduce host-label issues.

### 26. Why no custom SELinux policy?

The standard container policy already allows `container_t` to read
`container_file_t` when the MCS categories match. Correct volume labelling is
the supported, least-complex solution. A custom policy would be unnecessary and
could weaken confinement.

### 27. What is MCS?

Multi-Category Security. It adds categories such as `c191,c948` to the MLS
level. Containers get unique pairs so that two containers using the same type
still cannot access each other's files. `:Z` assigns a private pair.

### 28. What is an AVC?

Access Vector Cache record. The kernel logs denied (and some allowed) policy
decisions in this format. It is the primary evidence for an SELinux denial.
`permissive=0` means the denial was enforced.

### 29. `restorecon` versus `chcon`?

`restorecon` restores the label defined by the system policy for that path; it
is the correct, persistent fix. `chcon` sets a label manually and is temporary
(it can be undone by a relabel). The lab script uses `chcon` as a non-root
fallback for the user-owned lab directory; in normal administration use
`sudo restorecon -F -Rv data`. `-F` is needed after Docker `:Z` because plain
`restorecon` treats the Docker-set context as an admin customization and
preserves it.

### 30. What is defence in depth here?

Independent layers: input validation (app), non-root/read-only/cap-drop
(Docker), SELinux type/MCS (host), Kubernetes securityContext/seccomp/ClusterIP
(cluster), and read-only input volumes. A failure in one layer does not
automatically defeat the others.

### 31. Why is the Service port 80 but the container port 5000?

The Service provides a stable cluster-facing port (80) and maps it to the named
container port `http` (5000). This decouples clients from the container's
internal port and allows the app to change ports without changing clients.

### 32. Why `imagePullPolicy: Never`?

The image is loaded directly into Minikube and is not in a registry. `Never`
prevents Kubernetes from attempting a pull and failing. Use `IfNotPresent` if
you push the image to a registry.

### 33. What is the difference between health 503 and process 403?

503 means the input directory is missing or not readable (service-level
degradation). 403 means the directory is usable but the specific file could not
be opened (permission/SELinux denial). The distinction guides diagnosis.

### 34. What if SELinux were Permissive?

Denials would be logged but allowed. The API might succeed, but the security
demonstration would be invalid. This lab verifies `getenforce` is `Enforcing`
and `permissive=0` in the AVC.

### 35. Can `chmod 777` fix an SELinux denial?

No. DAC and MAC are independent. `chmod 777` can fix a DAC denial, but SELinux
still checks the type and MCS categories. The correct fix is a label change
(`:Z`, `:z`, `restorecon`), not broader Unix permissions.

### 36. Why not run the container as `--privileged`?

`--privileged` disables the isolation that the lab is demonstrating: it grants
all capabilities, device access and relaxed SELinux confinement. It would make
the restricted-operation tests meaningless.

---

## J. Complete demonstration checklist

Use this as the viva run sheet. Tick each item after showing the output.

### Preparation

- [ ] `cd /home/anique/DevOps_LabExam/cie`
- [ ] `getenforce` → `Enforcing`
- [ ] `sestatus | head` → `targeted`, enforcing
- [ ] `docker info --format '{{json .SecurityOptions}}'` → includes `selinux`
- [ ] `ls -Zd data` → note current label

### Build and run

- [ ] `./scripts/build.sh` → image `cie-worker:1.0`
- [ ] `./scripts/run.sh` → healthy, endpoint printed
- [ ] `docker ps -a --filter name=cie-worker` → `Up ... (healthy)`
- [ ] `curl -s http://127.0.0.1:5000/health | jq .` → 200/ok
- [ ] `curl -s 'http://127.0.0.1:5000/process?file=sample.txt' | jq .` → 114

### API security

- [ ] `./scripts/test.sh` → `PASS: 18 FAIL: 0`
- [ ] Show `file=../etc/passwd` → 400
- [ ] Show `file=/etc/passwd` → 400
- [ ] Show `file=missing.txt` → 404

### SELinux

- [ ] `./scripts/selinux-demo.sh` → denied read, AVC, then 200 with `:Z`
- [ ] `journalctl --since "15 min ago" | grep -i 'avc.*container_t'` → `permissive=0`
- [ ] `ls -Zd data` → `container_file_t:s0:cX,cY`
- [ ] `:z` shared read with two containers → label `container_file_t:s0` (no pair)
- [ ] `:Z` private read → label has an MCS pair
- [ ] `docker exec --user 10001:10001 cie-worker cat /proc/self/attr/current` → `container_t`
- [ ] `ps -eZ | grep container_t` → gunicorn processes

### Restricted operations

- [ ] `docker exec ... touch /data/evil.txt` → `Read-only file system`
- [ ] `docker exec ... touch /etc/evil.txt` → `Read-only file system`
- [ ] `docker exec ... cat /etc/shadow` → `Permission denied` (DAC)
- [ ] `docker exec ... grep Cap /proc/self/status` → all zero

### Inspection

- [ ] `./scripts/inspect.sh` → user, RO rootfs, caps, mount, network
- [ ] `docker logs --tail 20 cie-worker` → requests and errors
- [ ] `docker inspect ... --format '{{.State.ExitCode}}'` → 0
- [ ] Show a controlled `Exited (1)` container (optional)

### Troubleshooting

- [ ] Wrong mount target → 503/500, inspect shows `/data-input`, fix to `/data`
- [ ] `chmod 700 data` → 503/403, no AVC; `chmod 755` → 200
- [ ] Missing `:Z` → AVC/403; add `:Z` → 200
- [ ] `getenforce` after fixes → `Enforcing`

### Networking

- [ ] `docker network inspect cie-net` → bridge, subnet, worker
- [ ] One-off client on `cie-net` calls `http://cie-worker:5000/health` → 200

### Kubernetes

- [ ] `minikube status` → Running
- [ ] `minikube image load cie-worker:1.0`
- [ ] `kubectl apply -f kubernetes/namespace.yaml`
- [ ] `kubectl apply -f kubernetes/configmap.yaml -f kubernetes/deployment.yaml -f kubernetes/service.yaml`
- [ ] `kubectl -n cie get pods,svc` → 1/1 Running, ClusterIP
- [ ] `kubectl -n cie port-forward svc/cie-worker 8080:80`
- [ ] `BASE_URL=http://127.0.0.1:8080 ./scripts/test.sh` → 18/18
- [ ] `kubectl -n cie describe pod ...` → securityContext, probes, mounts
- [ ] `kubectl -n cie logs ...` → requests
- [ ] Show K8s failure/recovery (optional)
- [ ] Explain Minikube SELinux limitation (`enable_selinux=false`, `spc_t`)

### Wrap-up

- [ ] `getenforce` → `Enforcing` (final check)
- [ ] `docker inspect` → no `Privileged: true`, caps dropped, RO rootfs
- [ ] `sudo restorecon -F -Rv data` after the lab (manual, optional)
- [ ] `minikube stop` (optional)

---

## K. Limitations and manual steps

1. **`sudo ausearch` was not executed non-interactively.** `sudo` prompted for
   a password in this shell. AVC evidence was read from `journalctl`, which
   exposes the same audit records. Run `sudo ausearch -m AVC -ts recent` in a
   root shell if the examiner requires it.
2. **AppArmor is not installed.** Fedora uses SELinux; installing AppArmor was
   deliberately avoided.
3. **Minikube containerd has SELinux disabled.** Pods report `spc_t`, not
   `container_t`. Host SELinux is Enforcing, but it does not provide per-pod
   file-label enforcement here. Kubernetes security is demonstrated with
   securityContext, not AVCs.
4. **Minikube profile resource warning.** An existing profile cannot change
   memory. `minikube delete` first if you need different resources.
5. **Registry connectivity warning.** Minikube reported it could not reach
   `registry.k8s.io` from the host/node. This did not matter because the image
   was loaded locally with `minikube image load`.
6. **Host data label after `:Z`.** While the worker runs, `data/` is
   `container_file_t:s0:cX,cY`. Run `sudo restorecon -F -Rv data` after stopping
   the worker to restore `user_home_t`. Do not relabel system directories.
7. **MCS categories and pod names vary.** Do not compare exact `cX,cY` values
   or pod hashes between runs.
8. **Local Flask run is optional.** The implementation was validated through
   Docker and Kubernetes; the local venv instructions are for development.
9. **No authentication/TLS.** The API is loopback/ClusterIP-only, which is
   appropriate for the lab. Do not expose it to an untrusted network as-is.
10. **No custom SELinux policy.** Standard container policy plus correct
    labels is intentional and sufficient.

---

## Appendix — API and command reference

### API

| Method | Path | Query | Success | Errors |
|---|---|---|---|---|
| GET | `/health` | — | 200 `{status:ok,...}` | 503 if `/data` unusable |
| GET | `/process` | `file=<basename>` | 200 `{word_count,...}` | 400, 403, 404, 413, 500 |

Success response:

```json
{
  "status": "ok",
  "service": "cie-worker",
  "file": "sample.txt",
  "word_count": 114,
  "character_count": 733,
  "size_bytes": 733
}
```

Error response:

```json
{
  "status": "error",
  "error": {
    "code": "invalid_filename",
    "message": "Invalid filename. Use a plain file name such as 'sample.txt'."
  }
}
```

Error codes: `missing_file_parameter`, `invalid_filename`, `file_not_found`,
`file_inaccessible`, `path_traversal`, `not_a_regular_file`, `file_too_large`,
`input_directory_unavailable`, `read_error`, `path_resolution_error`,
`not_found`, `method_not_allowed`, `internal_error`.

### Commands

```bash
# Build / run / test
./scripts/build.sh
./scripts/run.sh
./scripts/test.sh
./scripts/stop.sh

# SELinux
./scripts/selinux-demo.sh
./scripts/inspect.sh
getenforce
sestatus
ls -Zd data
ps -eZ | grep container_t
journalctl --since "15 min ago" | grep -i 'avc.*container_t'
sudo ausearch -m AVC -ts recent
sudo restorecon -F -Rv data

# Docker
docker ps -a
docker inspect cie-worker
docker logs --tail 30 cie-worker
docker network inspect cie-net
docker exec --user 10001:10001 cie-worker sh

# Kubernetes
minikube start --driver=docker --cpus=2 --memory=4096
minikube image load cie-worker:1.0
kubectl apply -f kubernetes/namespace.yaml
kubectl apply -f kubernetes/configmap.yaml -f kubernetes/deployment.yaml -f kubernetes/service.yaml
kubectl -n cie get pods,svc
kubectl -n cie describe pod -l app.kubernetes.io/name=cie-worker
kubectl -n cie logs -l app.kubernetes.io/name=cie-worker --tail=30
kubectl -n cie port-forward svc/cie-worker 8080:80
BASE_URL=http://127.0.0.1:8080 ./scripts/test.sh
```

### File inventory

```text
app/app.py
app/requirements.txt
data/sample.txt
docker/Dockerfile
kubernetes/namespace.yaml
kubernetes/configmap.yaml
kubernetes/deployment.yaml
kubernetes/service.yaml
scripts/build.sh
scripts/run.sh
scripts/test.sh
scripts/selinux-demo.sh
scripts/inspect.sh
scripts/k8s-deploy.sh
scripts/stop.sh
docs/SECURITY.md
.dockerignore
.gitignore
README.md
```

---

**End of guide.** For the concise security evidence, see
[`docs/SECURITY.md`](docs/SECURITY.md).
