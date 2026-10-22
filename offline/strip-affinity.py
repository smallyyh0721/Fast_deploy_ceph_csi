#!/usr/bin/env python3
"""Remove top-level pod affinity block (indent '      affinity:') from a Deployment YAML."""
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src).read().splitlines(True)
out = []
i = 0
while i < len(lines):
    line = lines[i]
    if line.startswith("      affinity:"):
        indent = 6
        out.append("      # affinity removed for single-node (PROVISIONER_REPLICAS=1)\n")
        i += 1
        while i < len(lines):
            nxt = lines[i]
            if nxt.strip() == "":
                i += 1
                continue
            nindent = len(nxt) - len(nxt.lstrip(" "))
            if nindent > indent:
                i += 1
                continue
            break
        continue
    out.append(line)
    i += 1
open(dst, "w").writelines(out)
