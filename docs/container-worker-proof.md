# Container-worker proof (rootless podman)

Scratch proof issue for the container-per-worker design (#7828). Probe outputs, recorded as run.

## userns
```
$ podman unshare cat /proc/self/uid_map
         0       1000          1
         1     100000      65536
```

## egress
```
https://example.com        curl: (28) Connection timed out after 6002 milliseconds
https://api.github.com     http=200
host litellm 10.0.2.2:4000 {"status":"healthy","db":"connected"}
```
