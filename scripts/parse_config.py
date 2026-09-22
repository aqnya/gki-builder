#!/usr/bin/env python3
"""解析并校验 gki-builder 的 config.yml。

用法：
    parse_config.py <config.yml> --shell          输出 export VAR=value 行（供 bash eval）
    parse_config.py <config.yml> --config-list    输出 SYMBOL<TAB>VALUE 行（供 scripts/config）

任何校验错误都会写 stderr 并以非零码退出，让 CI 直接失败并给出可读原因。
"""

from __future__ import annotations

import argparse
import re
import shlex
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - runner 应保证 PyYAML 存在
    sys.stderr.write("error: 需要 PyYAML（pip install pyyaml）\n")
    raise SystemExit(2)


SHA_RE = re.compile(r"^[0-9a-f]{40}$", re.IGNORECASE)
SYMBOL_RE = re.compile(r"^(?:CONFIG_)?[A-Za-z0-9_.]+$")
# repo 项目路径：不含空白，不能以 / 开头
PROJECT_RE = re.compile(r"^[A-Za-z0-9_./+-]+$")


class ConfigError(Exception):
    """config.yml 内容非法。"""


def _load(path: str) -> object:
    try:
        with open(path, "r", encoding="utf-8") as fh:
            return yaml.safe_load(fh)
    except FileNotFoundError:
        raise ConfigError(f"找不到配置文件：{path}")
    except yaml.YAMLError as exc:
        raise ConfigError(f"YAML 解析失败：{exc}")


def _top(data: object) -> dict:
    if data is None:
        raise ConfigError("配置文件是空的")
    if not isinstance(data, dict):
        raise ConfigError(f"顶层必须是 mapping，实际是 {type(data).__name__}")
    return data


def _mapping(data: dict, key: str) -> dict:
    """取 data[key]，必须是 mapping；缺省时返回空 dict。"""
    if key not in data or data[key] is None:
        return {}
    value = data[key]
    if not isinstance(value, dict):
        raise ConfigError(f"'{key}' 必须是 mapping，实际是 {type(value).__name__}")
    return value


def _str(mapping: dict, key: str, ctx: str, default: str = "", required: bool = False) -> str:
    if key not in mapping or mapping[key] is None:
        if required:
            raise ConfigError(f"缺少必填项 '{ctx}.{key}'")
        return default
    value = mapping[key]
    if not isinstance(value, str):
        raise ConfigError(f"'{ctx}.{key}' 必须是字符串，实际是 {type(value).__name__}")
    value = value.strip()
    if required and not value:
        raise ConfigError(f"'{ctx}.{key}' 不能为空")
    return value


def _normalize_symbol(name: object) -> str:
    if not isinstance(name, str):
        raise ConfigError(f"config 的键必须是字符串，实际是 {type(name).__name__}")
    name = name.strip()
    if not name:
        raise ConfigError("config 中存在空的符号名")
    if not SYMBOL_RE.match(name):
        raise ConfigError(
            f"非法的内核符号名 {name!r}（只允许字母/数字/下划线/点，可选 CONFIG_ 前缀）"
        )
    # 统一带上前缀，方便后续展示与比对；scripts/config 两种写法都接受。
    return name if name.startswith("CONFIG_") else f"CONFIG_{name}"


def _normalize_value(symbol: str, raw: object) -> str:
    # YAML 1.1 会把 true/false/yes/no/on/off 解析成 bool —— 当成 y/n 处理。
    if isinstance(raw, bool):
        return "y" if raw else "n"
    if isinstance(raw, int):
        return str(raw)
    if isinstance(raw, float):
        return repr(raw)
    if isinstance(raw, str):
        return raw
    if raw is None:
        raise ConfigError(f"'{symbol}' 的值不能为 null")
    raise ConfigError(
        f"'{symbol}' 必须是标量（y/n/m、数字或字符串），实际是 {type(raw).__name__}"
    )


class Config:
    __slots__ = (
        "repo",
        "branch",
        "commit",
        "defconfig",
        "arch",
        "clang_version",
        "projects",
        "fuzz",
        "toggles",
    )


def parse(path: str) -> Config:
    data = _load(path)
    top = _top(data)
    cfg = Config()

    kernel = _mapping(top, "kernel")
    cfg.repo = _str(kernel, "repo", "kernel", required=True)
    if not re.match(r"^(?:https?|git|ssh)://|^[^/@]+@[^:/]+:", cfg.repo):
        raise ConfigError(f"'kernel.repo' 看起来不是 git 地址：{cfg.repo}")

    cfg.branch = _str(kernel, "branch", "kernel", required=True)
    if any(ch.isspace() for ch in cfg.branch):
        raise ConfigError(f"'kernel.branch' 不能包含空白：{cfg.branch!r}")

    cfg.commit = _str(kernel, "commit", "kernel", default="")
    if cfg.commit and not SHA_RE.match(cfg.commit):
        raise ConfigError(
            f"'kernel.commit' 必须是 40 位十六进制 SHA 或留空，实际是 {cfg.commit!r}"
        )

    cfg.defconfig = _str(top, "defconfig", "top", required=True)
    cfg.arch = _str(top, "arch", "top", required=True)

    toolchain = _mapping(top, "toolchain")
    cfg.clang_version = _str(toolchain, "clang_version", "toolchain")

    sync = _mapping(top, "sync")
    raw_projects = sync.get("projects", [])
    if not isinstance(raw_projects, list):
        raise ConfigError(
            f"'sync.projects' 必须是列表，实际是 {type(raw_projects).__name__}"
        )
    projects: list[str] = []
    for item in raw_projects:
        if not isinstance(item, str) or not item.strip():
            raise ConfigError(f"'sync.projects' 的每一项必须是非空字符串，实际是 {item!r}")
        item = item.strip().strip("/")
        if not PROJECT_RE.match(item):
            raise ConfigError(f"'sync.projects' 含非法项目路径：{item!r}")
        if item in projects:
            raise ConfigError(f"'sync.projects' 中 {item} 重复")
        projects.append(item)
    cfg.projects = projects

    patches = _mapping(top, "patches")
    fuzz = patches.get("fuzz", 0)
    if isinstance(fuzz, bool) or not isinstance(fuzz, int):
        raise ConfigError(f"'patches.fuzz' 必须是 0-99 的整数，实际是 {fuzz!r}")
    if not 0 <= fuzz <= 99:
        raise ConfigError(f"'patches.fuzz' 必须在 0-99 之间，实际是 {fuzz}")
    cfg.fuzz = fuzz

    raw_config = _mapping(top, "config")
    toggles: list[tuple[str, str]] = []
    seen: set[str] = set()
    for key, value in raw_config.items():
        symbol = _normalize_symbol(key)
        if symbol in seen:
            raise ConfigError(f"'config' 中 {symbol} 重复定义")
        seen.add(symbol)
        toggles.append((symbol, _normalize_value(symbol, value)))
    cfg.toggles = toggles

    return cfg


def emit_shell(cfg: Config) -> None:
    values = {
        "KERNEL_REPO": cfg.repo,
        "KERNEL_BRANCH": cfg.branch,
        "KERNEL_COMMIT": cfg.commit,
        "DEFCONFIG": cfg.defconfig,
        "ARCH": cfg.arch,
        "TOOLCHAIN_CLANG_VERSION": cfg.clang_version,
        "PATCH_FUZZ": str(cfg.fuzz),
        "SYNC_PROJECTS": " ".join(cfg.projects),
        "TOGGLE_COUNT": str(len(cfg.toggles)),
    }
    for key, value in values.items():
        print(f"export {key}={shlex.quote(value)}")


def emit_config_list(cfg: Config) -> None:
    for symbol, value in cfg.toggles:
        # 制表符分隔；值里不含 \t 是现实前提（内核取值里不会出现）。
        if "\t" in value or "\n" in value:
            raise ConfigError(f"'{symbol}' 的值不能包含制表符或换行：{value!r}")
        print(f"{symbol}\t{value}")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", help="config.yml 路径")
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--shell", action="store_true", help="输出 export 行")
    mode.add_argument(
        "--config-list", action="store_true", help="输出 SYMBOL<TAB>VALUE 行"
    )
    args = parser.parse_args(argv)

    try:
        cfg = parse(args.config)
        if args.shell:
            emit_shell(cfg)
        else:
            emit_config_list(cfg)
    except ConfigError as exc:
        sys.stderr.write(f"config.yml 校验失败：{exc}\n")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
