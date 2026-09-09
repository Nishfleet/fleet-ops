"""Patch LiteLLM 1.98 PrismaWrapper._write_engine for prisma-client-py 0.15.

prisma-client-py 0.15 stores the query engine on ``_internal_engine``
(BasePrisma.__slots__) and exposes it through the ``_engine`` property.
LiteLLM 1.98 still assigns the old mangled name:

    prisma_client._Prisma__engine = engine

On a slotted Prisma object that raises AttributeError ("'Prisma' object
has no attribute '_Prisma__engine'"), which aborts reconnect
(reason=engine_process_death) and leaves GET /health serving the empty
startup cache. fleet-ops#4628.

This directory is on the proxy's PYTHONPATH so the interpreter loads
this file as sitecustomize at startup, before LiteLLM imports Prisma.
The hook wraps the prisma_client loader and replaces _write_engine with
an assignment through the ``_engine`` setter, which works on 0.15 and
on older prisma that still kept the mangled name as a property.

Stdlib only. No secrets.
"""
from __future__ import annotations

import importlib.abc
import sys
from typing import Any

_PATCH_FLAG = "_fleet_engine_compat"


def _write_engine(prisma_client: Any, engine: Any) -> None:
    """Assign the engine through the public ``_engine`` setter."""
    prisma_client._engine = engine


def patch_write_engine(mod: Any) -> bool:
    """Replace PrismaWrapper._write_engine on a loaded prisma_client module.

    Returns True if the wrapper was patched (or was already patched).
    """
    wrapper = getattr(mod, "PrismaWrapper", None)
    if wrapper is None:
        return False
    if getattr(wrapper, _PATCH_FLAG, False):
        return True
    wrapper._write_engine = staticmethod(_write_engine)
    setattr(wrapper, _PATCH_FLAG, True)
    return True


class _PrismaClientFinder(importlib.abc.MetaPathFinder):
    """Delegate-load litellm.proxy.db.prisma_client, then patch _write_engine."""

    def find_spec(self, fullname: str, path: Any, target: Any = None) -> Any:
        if fullname != "litellm.proxy.db.prisma_client":
            return None
        for finder in sys.meta_path:
            if finder is self:
                continue
            find_spec = getattr(finder, "find_spec", None)
            if find_spec is None:
                continue
            spec = find_spec(fullname, path, target)
            if spec is None or spec.loader is None:
                continue
            orig_exec = spec.loader.exec_module

            def exec_module(module: Any, _orig: Any = orig_exec) -> None:
                _orig(module)
                patch_write_engine(module)

            spec.loader.exec_module = exec_module  # type: ignore[method-assign]
            return spec
        return None


def install() -> None:
    """Idempotent: install the import hook once."""
    if any(isinstance(f, _PrismaClientFinder) for f in sys.meta_path):
        return
    already = sys.modules.get("litellm.proxy.db.prisma_client")
    if already is not None:
        patch_write_engine(already)
        return
    sys.meta_path.insert(0, _PrismaClientFinder())


install()
