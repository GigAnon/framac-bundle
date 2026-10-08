#!/usr/bin/env python3
# MOCK lib/make_machdep/make_machdep.py: like the real one, needs PyYAML
import argparse
import yaml  # noqa: F401  (ModuleNotFoundError without PyYAML)
p = argparse.ArgumentParser(description="mock make_machdep")
p.add_argument("--machdep-schema"); p.add_argument("--compiler")
a = p.parse_args()
