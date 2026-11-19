#!/usr/bin/env python3
"""Check the facts this repo states in more than one place.

CLAUDE.md's "Keep in sync" table lists them. The ones that can be read out of
the files, rather than judged, are checked here, so a change to one place that
misses the others fails CI instead of surfacing in a user's deploy:

- the tileserver-gl pin, and the x-logging block, across the Compose files
- MapProxy's version across Dockerfile.mapproxy, Compose, the image workflow
  and every place the docs repeat it
- the set of styles across tileserver/styles/, config.json, sync-styles.yml
  and both MapProxy configs, and the "six styles" / "18 layers" counts in docs
- the style.json rules TileserverGL depends on (sources, sprite, glyphs)
- the public mirror in deploy.sh, deploy.ps1 and the README
- the UWSGI_PROCESSES / UWSGI_CHEAPER defaults everywhere they appear, and
  that uWSGI's harakiri stays below nginx's proxy_read_timeout
- the Docker Engine and Compose minimums in both scripts and the docs

Needs PyYAML (a MapProxy dependency, so it is already there when the MapProxy
config check can run).

    python3 .github/scripts/check-sync.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Callable

import yaml

ROOT = Path(__file__).resolve().parents[2]

COMPOSE_FILES = (
    "docker-compose.yaml",
    "docker-compose.override.yaml",
    "docker-compose.4087.yaml",
)
VERSION = r"\d+\.\d+\.\d+"
NUMBER_WORDS = {
    "two": 2,
    "three": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
    "ten": 10,
    "eleven": 11,
    "twelve": 12,
}
PROJECTIONS_PER_STYLE = 3  # EPSG:3857, EPSG:3395 and EPSG:4326 (EPSG:4087 is a cache only)

Rule = Callable[[list[str]], None]
RULES: list[Rule] = []


def rule(func: Rule) -> Rule:
    RULES.append(func)
    return func


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def load_yaml(rel: str) -> dict:
    return yaml.safe_load(read(rel))


def find_one(pattern: str, rel: str, problems: list[str], what: str, flags: int = re.M) -> str | None:
    """The first capture group of `pattern` in `rel`, or a problem if it's gone.
    A refactor that renames the line has to update the check too, not skip it."""
    match = re.search(pattern, read(rel), flags)
    if not match:
        problems.append(f"{rel}: can't find {what} (pattern {pattern!r}); update check-sync.py")
        return None
    return match.group(1)


def doc_files() -> list[str]:
    docs = sorted(str(p.relative_to(ROOT)) for p in (ROOT / "docs").glob("*.md"))
    return ["README.md", "CLAUDE.md", "CONTEXT.md", "CONTRIBUTING.md", *docs]


def style_dirs() -> list[str]:
    root = ROOT / "tileserver" / "styles"
    return sorted(p.name for p in root.iterdir() if p.is_dir() and p.name.startswith("RBT-"))


def short_name(style_dir: str) -> str:
    """RBT-TOPO -> topo, the middle of rbt_topo_3857."""
    return style_dir.removeprefix("RBT-").lower()


def same(label: str, values: dict[str, object], problems: list[str]) -> None:
    """One problem if the places in `values` don't all hold the same thing."""
    if len({json.dumps(v, sort_keys=True) for v in values.values()}) > 1:
        shown = "; ".join(f"{where}: {value}" for where, value in values.items())
        problems.append(f"{label} differs -- {shown}")


# -- Compose -------------------------------------------------------------------


@rule
def tileserver_pin(problems: list[str]) -> None:
    """tileserver-gl is pinned in docker-compose.yaml and docker-compose.4087.yaml."""
    same(
        "the tileserver-gl image",
        {
            "docker-compose.yaml": load_yaml("docker-compose.yaml")["services"]["tileservergl"][
                "image"
            ],
            "docker-compose.4087.yaml": load_yaml("docker-compose.4087.yaml")["services"][
                "tileservergl4087"
            ]["image"],
        },
        problems,
    )


@rule
def logging_blocks(problems: list[str]) -> None:
    """The x-logging block is repeated in each Compose file (anchors don't cross files)."""
    blocks = {}
    for rel in COMPOSE_FILES:
        block = load_yaml(rel).get("x-logging")
        if block is None:
            problems.append(f"{rel}: has no x-logging block")
        else:
            blocks[rel] = block
    same("the x-logging block", blocks, problems)


# -- MapProxy's version --------------------------------------------------------

# Every spelling of the version the repo uses. The first group is the version.
MAPPROXY_VERSION_PATTERNS = (
    re.compile(rf"(?:rbt-mapproxy|rbt-local/mapproxy|mapproxy/mapproxy):({VERSION})"),
    re.compile(rf"MapProxy(?:==| )({VERSION})"),
    re.compile(rf"MAPPROXY_VERSION=({VERSION})"),
    re.compile(rf"type=raw,value=({VERSION})"),
)
# On a line about MapProxy, a bare version in quotes or backticks is its version.
QUOTED_VERSION = re.compile(rf"[`\"]({VERSION})[`\"]")


@rule
def mapproxy_version(problems: list[str]) -> None:
    """Every mention of MapProxy's version matches ARG MAPPROXY_VERSION."""
    expected = find_one(
        rf"^ARG MAPPROXY_VERSION=({VERSION})$", "Dockerfile.mapproxy", problems, "ARG MAPPROXY_VERSION"
    )
    if expected is None:
        return

    image = load_yaml("docker-compose.yaml")["services"]["mapproxy"]["image"]
    if image != f"rbt-mapproxy:{expected}":
        problems.append(
            f"docker-compose.yaml: the mapproxy image is {image}, but Dockerfile.mapproxy "
            f"installs {expected}"
        )
    find_one(
        rf"type=raw,value=({VERSION})",
        ".github/workflows/mapproxy-image.yml",
        problems,
        "the published image tag",
    )

    files = [
        *doc_files(),
        "Dockerfile.mapproxy",
        "mapproxy/docker/app.py",
        *COMPOSE_FILES,
        *sorted(str(p.relative_to(ROOT)) for p in (ROOT / ".github" / "workflows").glob("*.yml")),
    ]
    for rel in files:
        for number, line in enumerate(read(rel).splitlines(), 1):
            found = [m.group(1) for pattern in MAPPROXY_VERSION_PATTERNS for m in pattern.finditer(line)]
            if "mapproxy" in line.lower():
                found += QUOTED_VERSION.findall(line)
            for version in found:
                if version != expected:
                    problems.append(
                        f"{rel}:{number}: mentions MapProxy {version}, but Dockerfile.mapproxy "
                        f"installs {expected}"
                    )


# -- Styles --------------------------------------------------------------------


@rule
def style_sets(problems: list[str]) -> None:
    """The set of styles agrees across the directories, configs, workflow and docs.

    Each style has a directory, a config.json entry, a sync-styles.yml path, a
    MapProxy source, three caches and three layers (plus the 4087 source and
    cache in the 4087 stack), and the docs count them right."""
    dirs = style_dirs()
    if not dirs:
        problems.append("tileserver/styles/ has no RBT-* directories")
        return

    config = json.loads(read("tileserver/config/config.json"))
    same("the style set", {
        "tileserver/styles/": dirs,
        "tileserver/config/config.json": sorted(config["styles"]),
        ".github/workflows/sync-styles.yml sparse-checkout": sorted(
            re.findall(r"^\s+styles/(RBT-[A-Z0-9-]+)\s*$", read(".github/workflows/sync-styles.yml"), re.M)
        ),
    }, problems)
    for name, entry in config["styles"].items():
        if entry.get("style") != f"{name}/style.json":
            problems.append(
                f"config.json: style {name} points at {entry.get('style')}, not {name}/style.json"
            )

    shorts = [short_name(d) for d in dirs]
    base = load_yaml("mapproxy/config/mapproxy.yaml")
    overlay = load_yaml("mapproxy/config/mapproxy.4087.yaml")
    epsgs = ("3857", "3395", "4326")

    def compare(where: str, actual: object, expected: list[str]) -> None:
        if sorted(actual) != sorted(expected):
            problems.append(
                f"{where}: {sorted(actual)} does not match the styles' {sorted(expected)}"
            )

    compare("mapproxy.yaml sources", base["sources"], [f"rbt_{s}_source" for s in shorts])
    compare("mapproxy.yaml caches", base["caches"], [f"rbt_{s}_{e}_cache" for s in shorts for e in epsgs])
    compare(
        "mapproxy.yaml layers",
        [layer["name"] for layer in base["layers"]],
        [f"rbt_{s}_{e}" for s in shorts for e in epsgs],
    )
    compare("mapproxy.4087.yaml sources", overlay["sources"], [f"rbt_{s}_4087_source" for s in shorts])
    compare(
        "mapproxy.4087.yaml caches",
        overlay["caches"],
        [f"rbt_{s}_{e}_cache" for s in shorts for e in ("4087", "4326")],
    )

    for d in dirs:
        short = short_name(d)
        for where, name, host in (
            ("mapproxy.yaml", f"rbt_{short}_source", "tileservergl:8080"),
            ("mapproxy.4087.yaml", f"rbt_{short}_4087_source", "tileservergl4087:8080"),
        ):
            sources = (base if where == "mapproxy.yaml" else overlay)["sources"]
            expected_url = f"http://{host}/styles/{d}/512/%(z)s/%(x)s/%(y)s.png"
            url = sources.get(name, {}).get("url")
            if url != expected_url:
                problems.append(f"{where}: source {name} reads {url}, expected {expected_url}")

    layers = len(dirs) * PROJECTIONS_PER_STYLE
    for rel in doc_files():
        for number, line in enumerate(read(rel).splitlines(), 1):
            for word in re.findall(r"(?i)\b(\d+|" + "|".join(NUMBER_WORDS) + r")\s+(?:RBT\s+)?styles\b", line):
                count = int(word) if word.isdigit() else NUMBER_WORDS[word.lower()]
                if count != len(dirs):
                    problems.append(f"{rel}:{number}: says {word} styles, but there are {len(dirs)}")
            # \d{1,3} keeps "EPSG:3857 and 3395 layers" from reading as a count
            for count in re.findall(r"\b(\d{1,3})\s+layers\b", line):
                if int(count) != layers:
                    problems.append(f"{rel}:{number}: says {count} layers, but there are {layers}")


@rule
def style_json_rules(problems: list[str]) -> None:
    """Each style.json points at what TileserverGL serves.

    sync-styles.py rewrites upstream styles to these values, but nothing else
    checks a hand edit."""
    sources = {"RBT": "mbtiles://{RBT}", "TERRAIN": "mbtiles://{TERRAIN}"}
    for d in style_dirs():
        rel = f"tileserver/styles/{d}/style.json"
        style = json.loads(read(rel))
        found = style.get("sources", {})
        if "RBT" not in found:
            problems.append(f"{rel}: has no sources.RBT")
        for name, source in found.items():
            if name not in sources:
                problems.append(f"{rel}: sources.{name} isn't served (only RBT and TERRAIN are)")
            elif source.get("url") != sources[name]:
                problems.append(f"{rel}: sources.{name}.url is {source.get('url')}, want {sources[name]}")
        if style.get("sprite") != "{styleJsonFolder}/sprite":
            problems.append(f"{rel}: sprite is {style.get('sprite')}, want {{styleJsonFolder}}/sprite")
        if style.get("glyphs") != "{fontstack}/{range}.pbf":
            problems.append(f"{rel}: glyphs is {style.get('glyphs')}, want {{fontstack}}/{{range}}.pbf")


# -- The public mirror ---------------------------------------------------------


@rule
def public_mirror(problems: list[str]) -> None:
    """PUBLIC_S3_* in deploy.sh, $script:PublicS3* in deploy.ps1, and the README."""
    shell = dict(re.findall(r'^PUBLIC_S3_(\w+)="([^"]*)"', read("deploy.sh"), re.M))
    # PREFIX_3857 -> Prefix3857, the spelling deploy.ps1 uses
    shell = {"".join(part.capitalize() for part in k.split("_")): v for k, v in shell.items()}
    power = dict(re.findall(r"^\$script:PublicS3(\w+) = '([^']*)'", read("deploy.ps1"), re.M))
    if not shell or not power:
        problems.append("can't find PUBLIC_S3_* in deploy.sh or $script:PublicS3* in deploy.ps1")
        return
    same("the public mirror settings", {"deploy.sh": shell, "deploy.ps1": power}, problems)

    readme = read("README.md")
    for key in ("Endpoint", "Region"):
        value = shell.get(key)
        if value and value not in readme:
            problems.append(f"README.md: doesn't mention the public mirror's {key.lower()} {value}")


# -- uWSGI and nginx -----------------------------------------------------------


@rule
def uwsgi_defaults(problems: list[str]) -> None:
    """The UWSGI_PROCESSES and UWSGI_CHEAPER defaults agree, and CHEAPER < PROCESSES.

    uWSGI won't start with CHEAPER at or above PROCESSES."""
    places = {
        "docker-compose.yaml": (
            r"UWSGI_PROCESSES=\$\{UWSGI_PROCESSES:-(\d+)\}",
            r"UWSGI_CHEAPER=\$\{UWSGI_CHEAPER:-(\d+)\}",
        ),
        "Dockerfile.mapproxy": (r"\bUWSGI_PROCESSES=(\d+)\b", r"\bUWSGI_CHEAPER=(\d+)\b"),
        ".env.example": (r"^#?UWSGI_PROCESSES=(\d+)$", r"^#?UWSGI_CHEAPER=(\d+)$"),
        "deploy.sh": (r"\$\{UWSGI_PROCESSES:-(\d+)\}", r"\$\{UWSGI_CHEAPER:-(\d+)\}"),
        "deploy.ps1": (
            r"\$env:UWSGI_PROCESSES \} else \{ '(\d+)' \}",
            r"\$env:UWSGI_CHEAPER \} else \{ '(\d+)' \}",
        ),
    }
    processes, cheaper = {}, {}
    for rel, (p_pattern, c_pattern) in places.items():
        p = find_one(p_pattern, rel, problems, "the UWSGI_PROCESSES default")
        c = find_one(c_pattern, rel, problems, "the UWSGI_CHEAPER default")
        if p is not None and c is not None:
            processes[rel], cheaper[rel] = int(p), int(c)
            if int(c) >= int(p):
                problems.append(f"{rel}: UWSGI_CHEAPER ({c}) must stay below UWSGI_PROCESSES ({p})")
    same("the UWSGI_PROCESSES default", processes, problems)
    same("the UWSGI_CHEAPER default", cheaper, problems)


@rule
def timeouts(problems: list[str]) -> None:
    """uWSGI's harakiri stays below nginx's proxy_read_timeout.

    That way uWSGI kills a stuck worker and answers before nginx gives up."""
    harakiri = find_one(r"^harakiri\s*=\s*(\d+)\b", "mapproxy/config/uwsgi.ini", problems, "harakiri")
    timeouts = [int(t) for t in re.findall(r"^\s*proxy_read_timeout\s+(\d+)s;", read("nginx/config/nginx.conf"), re.M)]
    if not timeouts:
        problems.append("nginx/config/nginx.conf: can't find proxy_read_timeout; update check-sync.py")
    for timeout in timeouts:
        if harakiri is not None and int(harakiri) >= timeout:
            problems.append(
                f"uwsgi.ini harakiri ({harakiri}s) must stay below nginx's proxy_read_timeout ({timeout}s)"
            )


# -- Docker minimums -----------------------------------------------------------


@rule
def docker_minimums(problems: list[str]) -> None:
    """The Docker Engine and Compose minimums agree in both scripts and the docs."""
    shell_compose = find_one(rf'^MIN_COMPOSE_VERSION="({VERSION})"', "deploy.sh", problems, "MIN_COMPOSE_VERSION")
    shell_engine = find_one(rf'^MIN_DOCKER_ENGINE_VERSION="({VERSION})"', "deploy.sh", problems, "MIN_DOCKER_ENGINE_VERSION")
    power_compose = find_one(
        rf"^\$script:MinComposeVersion = \[version\]'({VERSION})'", "deploy.ps1", problems, "MinComposeVersion"
    )
    power_engine = find_one(
        rf"^\$script:MinDockerEngineVersion = \[version\]'({VERSION})'", "deploy.ps1", problems, "MinDockerEngineVersion"
    )
    if None in (shell_compose, shell_engine, power_compose, power_engine):
        return
    same("the minimum Compose version", {"deploy.sh": shell_compose, "deploy.ps1": power_compose}, problems)
    same("the minimum Docker Engine version", {"deploy.sh": shell_engine, "deploy.ps1": power_engine}, problems)

    compose_minor = ".".join(shell_compose.split(".")[:2])
    engine_major = shell_engine.split(".")[0]
    readme = re.search(r"Docker Engine (\d+) or newer with Compose (\d+\.\d+) or newer", read("README.md"))
    if not readme:
        problems.append("README.md: can't find the Requirements line naming the Docker minimums; update check-sync.py")
    elif (readme.group(1), readme.group(2)) != (engine_major, compose_minor):
        problems.append(
            f"README.md: asks for Engine {readme.group(1)} and Compose {readme.group(2)}, but the "
            f"scripts need Engine {engine_major} and Compose {compose_minor}"
        )
    trouble = re.search(
        rf"older than ({VERSION}) or the Docker Engine is older than (\d+)", read("docs/troubleshooting.md")
    )
    if not trouble:
        problems.append("docs/troubleshooting.md: can't find the 'older than' minimums; update check-sync.py")
    elif (trouble.group(1), trouble.group(2)) != (shell_compose, engine_major):
        problems.append(
            f"docs/troubleshooting.md: names Compose {trouble.group(1)} and Engine {trouble.group(2)}, "
            f"but the scripts need Compose {shell_compose} and Engine {engine_major}"
        )


def main() -> int:
    problems: list[str] = []
    for check in RULES:
        found: list[str] = []
        check(found)
        status = "FAIL" if found else "ok"
        print(f"{status:>4}  {check.__name__}: {(check.__doc__ or '').splitlines()[0]}")
        problems += [f"{check.__name__}: {problem}" for problem in found]
    if problems:
        print(f"\n{len(problems)} problem(s):", file=sys.stderr)
        for problem in problems:
            print(f"  {problem}", file=sys.stderr)
        return 1
    print(f"OK check-sync: {len(RULES)} rules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
