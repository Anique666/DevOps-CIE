# Security Design and Evidence

This document explains the security model of the worker and records the
evidence collected in the lab environment. The README is the primary lab
guide; this file is the concise security reference.

Environment used:

| Item | Value |
|---|---|
| OS | Fedora Linux 44 (Workstation) |
| Kernel | 6.19.10-300.fc44.x86_64 |
| SELinux | `targeted`, **Enforcing** |
| Docker | 29.7.2, `overlayfs`, `--selinux-enabled` |
| Minikube | v1.39.0, docker driver, containerd 2.3.4 |
| Kubernetes | v1.37.0 |

## 1. Assets and trust boundaries

Assets:

* The text documents in `data/` (read-only input).
* The worker process and its image.
* The host filesystem and other host containers.

Trust boundaries:

* API client -> Flask worker (untrusted filename input).
* Container -> host filesystem (bind mount + SELinux label).
* Pod -> node/host (Kubernetes securityContext; Minikube node).
* Worker -> Docker bridge network (only the required HTTP port).

Non-goals for this lab: authentication, TLS, rate limiting, a database,
multi-tenancy, and protection against a kernel/container-runtime escape.

## 2. Controls

| Layer | Control | What it prevents |
|---|---|---|
| Application | Strict basename allow-list + resolved-path containment | Path traversal, absolute paths, symlink escape |
| Application | 1 MiB size limit, regular-file check, structured errors | Oversized/special-file reads, information leaks in stack traces |
| Docker | `USER 10001:10001` | Running as root inside the container |
| Docker | `--read-only` + `--tmpfs /tmp` | Persisting changes in the image/root filesystem |
| Docker | `--cap-drop ALL` | Capability-based privilege (e.g. `CAP_DAC_OVERRIDE`, `CAP_SYS_ADMIN`) |
| Docker | `--security-opt no-new-privileges:true` | Gaining privileges through setuid/setgid binaries |
| Docker | `-v ...:/data:ro,Z` | Writing input files; SELinux type/MCS mismatch |
| Docker | `-p 127.0.0.1:5000:5000` | Exposing the API to the LAN |
| SELinux | `container_t` process, `container_file_t` input, private MCS pair | Reading unrelated host files even if DAC would allow it |
| Kubernetes | `runAsNonRoot`, `runAsUser/Group`, `fsGroup` | Root pods |
| Kubernetes | `allowPrivilegeEscalation: false`, `capabilities.drop: ALL` | Privilege escalation and capabilities |
| Kubernetes | `readOnlyRootFilesystem: true`, read-only ConfigMap | Runtime filesystem modification |
| Kubernetes | `seccompProfile: RuntimeDefault` | Unnecessary syscalls |
| Kubernetes | ClusterIP Service + `kubectl port-forward` | External exposure |

## 3. Three different denial mechanisms

These are deliberately kept distinct. Do not attribute a failure to SELinux
unless there is an AVC record (or an equivalent SELinux enforcement signal).

### 3.1 Ordinary Linux permissions (DAC)

Observed:

```text
$ docker exec --user 10001:10001 cie-worker cat /etc/shadow
cat: /etc/shadow: Permission denied
```

Root owns `/etc/shadow`; mode `0640` (or stricter). UID 10001 is not root and
not in the `shadow` group. No AVC is generated because SELinux allowed the
attempt and DAC rejected it.

The lab also reproduces this on the input directory:

```text
$ chmod 700 data
$ curl '.../process?file=sample.txt'
HTTP 403  {"error":{"code":"file_inaccessible", ...}}
$ chmod 755 data
$ curl '.../process?file=sample.txt'
HTTP 200  {"word_count":114, ...}
```

No AVC appears for `name="data"`; this is a DAC denial.

### 3.2 Docker security configuration

Observed:

```text
$ docker exec --user 10001:10001 cie-worker touch /data/evil.txt
touch: cannot touch '/data/evil.txt': Read-only file system

$ docker exec --user 10001:10001 cie-worker touch /etc/evil.txt
sh: 1: cannot create /etc/evil.txt: Read-only file system
```

The kernel returns `EROFS` because the bind mount is `ro` and the container
root filesystem is `--read-only`. This is not an SELinux decision.

### 3.3 SELinux mandatory access control

Observed AVC (journald, enforcing mode):

```text
AVC avc: denied { read } for pid=16668 comm="python" name="sample.txt"
  dev="nvme0n1p3" ino=3181992
  scontext=system_u:system_r:container_t:s0:c143,c877
  tcontext=unconfined_u:object_r:user_home_t:s0
  tclass=file permissive=0
```

`permissive=0` means the denial was enforced, not merely logged. The file was
mode `0644` and readable by its owner, so DAC was not the blocker. The
container type `container_t` is not allowed to read the user home type
`user_home_t`; the MCS categories also do not match.

At the API level the same denial appears as:

```text
GET /health -> HTTP 503
{"status":"degraded","input_dir_exists":true,"input_dir_readable":false}

GET /process?file=sample.txt -> HTTP 403
{"error":{"code":"file_inaccessible",
          "message":"The worker is not permitted to read this file."}}
```

After adding `:Z`, the host directory becomes
`system_u:object_r:container_file_t:s0:cX,cY` (values vary), matching the
container's private category, and the request succeeds.

## 4. `:Z` versus `:z`

* `:Z` applies a **private, unshared** label: type `container_file_t` plus a
  unique MCS pair for this container. Use it when exactly one container needs
  the directory. This lab uses `:Z` for the worker.
* `:z` applies a **shared** label: multiple containers may use the same
  content. It is appropriate for shared read-only content but provides less
  isolation between the containers.
* Docker recursively relabels the host source when `:Z` is used.
* If two containers use `:Z` on the same host directory, the second start
  relabels the directory and the first container's MCS pair no longer matches.
  This was observed during the lab: a second `:Z` container caused the first
  worker to return 403 until the worker was restarted with its own `:Z` label.
  The correct fixes are: use one dedicated directory per container, use `:z`
  for genuinely shared content, or restart the affected container after the
  relabel.
* Demonstrated `:z` behaviour: with two containers using
  `-v "$PWD/data:/data:ro,z"`, both could read `sample.txt` and the host label
  was `container_file_t:s0` with **no** private MCS pair. With `:Z`, the label
  gains a private pair (for example `s0:c332,c352`).
* MCS categories are generated per container start; exact values vary.
* After the lab, restore the normal host label with
  `sudo restorecon -F -Rv data`. The `-F` is required after Docker `:Z` because
  plain `restorecon` treats the Docker-set context as an admin customization
  and preserves it. The `data/` directory is a user lab directory, not a system
  directory; never run `restorecon`/`chcon` blindly on `/etc`, `/usr`, `/var`,
  or other system paths.

## 5. SELinux contexts in this experiment

Host data directory before Docker:

```text
unconfined_u:object_r:user_home_t:s0
```

Host data directory after `-v "$PWD/data:/data:ro,Z"`:

```text
system_u:object_r:container_file_t:s0:cX,cY
```

Container process:

```text
system_u:system_r:container_t:s0:cX,cY
```

The user, role, type, and level/category fields all matter:

* `system_u` / `unconfined_u`: SELinux user.
* `object_r` / `system_r`: role.
* `container_file_t` / `user_home_t` / `container_t`: type (the main
  type-enforcement decision).
* `s0:cX,cY`: MLS/MCS level and categories (container isolation; values vary).

## 6. Kubernetes-specific limitation

The host runs SELinux Enforcing, and the Minikube node container runs under the
host policy as the privileged container type `spc_t`. However, **pods inside
Minikube are not individually SELinux-confined** in this setup:

```text
$ minikube ssh -- getenforce
bash: getenforce: command not found

$ minikube ssh -- cat /proc/self/attr/current
system_u:system_r:spc_t:s0

$ minikube ssh -- sudo cat /etc/containerd/config.toml | grep enable_selinux
enable_selinux = false
```

Inside the pod:

```text
$ kubectl -n cie exec ... -- cat /proc/self/attr/current
system_u:system_r:spc_t:s0
```

Therefore the Kubernetes deployment relies on:

* `runAsNonRoot`, fixed UID/GID;
* `allowPrivilegeEscalation: false`;
* `capabilities.drop: ALL`;
* `readOnlyRootFilesystem: true`;
* read-only ConfigMap volume;
* `seccompProfile: RuntimeDefault`;
* ClusterIP-only Service.

Host Docker bind-mount labels (`:Z`) do not automatically apply to
Kubernetes volumes. The Kubernetes input is a ConfigMap volume managed by the
kubelet, not a host bind mount. Do not claim SELinux protects the pod in this
Minikube configuration.

## 7. Residual risks

* The API has no authentication; it is bound to loopback and ClusterIP only,
  which is appropriate for the lab but not for an untrusted network.
* Input files are trusted text files. The app limits size but does not scan
  content for malware.
* A compromised container could still consume CPU/memory; Kubernetes resource
  limits and Docker defaults reduce but do not eliminate denial-of-service
  risk.
* The image uses `python:3.12-slim` and installs pinned Python packages, but
  base-image CVEs are out of scope for this lab.
* No custom SELinux policy was written; the standard container policy and
  correct volume labels are sufficient for the demonstrated controls.
* Minikube's containerd has SELinux disabled, so the Kubernetes phase is not a
  SELinux enforcement demonstration. It is a defense-in-depth/securityContext
  demonstration.

## 8. Verification commands

```bash
getenforce
sestatus
ls -Zd data
ps -eZ | grep container_t
journalctl --since '15 min ago' | grep -i 'avc.*container_t'
sudo ausearch -m AVC -ts recent | grep -i container_t
docker inspect cie-worker
docker logs --tail 30 cie-worker
docker ps -a
kubectl -n cie get pods,svc
kubectl -n cie describe pod -l app.kubernetes.io/name=cie-worker
kubectl -n cie logs -l app.kubernetes.io/name=cie-worker --tail=30
```

`ausearch` requires root. In the lab shell, `sudo` prompted for a password, so
the AVC evidence above was read with `journalctl` from the same audit stream.
Run the `ausearch` command manually in a root shell if required by the
examiner.
