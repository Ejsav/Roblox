#!/usr/bin/env python3
"""
Static wiring checks that a runtime spec cannot make.

The suite runs modules in isolation, so it can prove a service behaves correctly
while the game never calls it. These checks read the source instead and catch the
class of bug where something is fully built and entirely unreachable:

  1. Every client-sendable remote has exactly one server handler.
  2. Every server-to-client remote is fired by something.
  3. Every service module on disk is registered in the bootstrap.
  4. Every screen module on disk is constructed by the menu controller.

Exits non-zero and names the offender.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
        return handle.read()


def walk(directory, suffix=".luau"):
    out = []
    for dirpath, _, filenames in os.walk(os.path.join(ROOT, directory)):
        for name in filenames:
            if name.endswith(suffix):
                out.append(os.path.join(dirpath, name))
    return out


def remote_blocks():
    text = read("src/Shared/Net/Remotes.luau")
    # Definitions are one indent deep inside Remotes.Definitions.
    return re.findall(r"^\t([A-Za-z]\w*) = \{(.*?)^\t\},", text, re.M | re.S)


def check_remotes(problems):
    server_text = "\n".join(read(os.path.relpath(p, ROOT)) for p in walk("src/Server"))
    client_text = "\n".join(read(os.path.relpath(p, ROOT)) for p in walk("src/Client"))

    # Call sites are frequently wrapped across lines, so every pattern tolerates
    # whitespace after the open paren and an optional leading argument.
    handlers = re.findall(r'Net\.OnServerEvent\(\s*"(\w+)"', server_text)
    handler_counts = {}
    for name in handlers:
        handler_counts[name] = handler_counts.get(name, 0) + 1

    # FireClient/FireClients take a recipient first; FireAllClients does not.
    # The recipient argument may itself be a call, so it may contain parentheses;
    # it may not contain a quote, which is what distinguishes it from the name.
    fired = set(re.findall(r'Net\.Fire\w*\(\s*(?:[^,"]+?,\s*)?"(\w+)"', server_text))
    listened = set(re.findall(r'Net\.OnClientEvent\(\s*"(\w+)"', client_text))
    invoked = set(re.findall(r'Net\.InvokeServer\(\s*"(\w+)"', client_text))
    sent = set(re.findall(r'Net\.FireServer\(\s*"(\w+)"', client_text))

    for name, body in remote_blocks():
        direction = re.search(r'direction = "(\w+)"', body)
        if not direction:
            problems.append(f"remote {name} declares no direction")
            continue
        direction = direction.group(1)

        if direction.startswith("C2S"):
            count = handler_counts.get(name, 0)
            if count == 0:
                problems.append(f"remote {name} is client-sendable but no server handler binds it")
            elif count > 1:
                problems.append(f"remote {name} has {count} server handlers; exactly one owns a remote")

            if name not in invoked and name not in sent:
                problems.append(f"remote {name} is client-sendable but no client ever sends it")

        elif direction == "S2C":
            if name not in fired:
                problems.append(f"remote {name} is server-to-client but nothing on the server fires it")
            if name not in listened:
                problems.append(f"remote {name} is server-to-client but no client listens for it")


def check_services(problems):
    bootstrap = read("src/Server/init.server.luau")
    registered = set(re.findall(r'^\t"(\w+)",', bootstrap, re.M))

    for path in walk("src/Server/Services"):
        name = os.path.basename(path)[: -len(".luau")]
        if name not in registered:
            problems.append(f"service {name} exists but is not registered in the bootstrap")


def check_screens(problems):
    menu = read("src/Client/Controllers/MenuController.luau")
    constructed = set(re.findall(r"(\w+Screen)\.new\(", menu))

    for path in walk("src/Client/UI/Screens"):
        name = os.path.basename(path)[: -len(".luau")]
        # The HUD is owned by HudController, not the menu.
        if name == "Hud":
            continue
        if name not in constructed:
            problems.append(f"screen {name} exists but the menu never constructs it")


def main():
    problems = []
    check_remotes(problems)
    check_services(problems)
    check_screens(problems)

    if problems:
        print(f"Wiring: {len(problems)} problem(s)")
        for problem in problems:
            print("  " + problem)
        return 1

    print("Wiring: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
