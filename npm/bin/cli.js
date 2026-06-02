#!/usr/bin/env node
"use strict";

const { execFileSync } = require("child_process");
const { createInterface } = require("readline");
const path = require("path");
const fs = require("fs");
const os = require("os");

const SCRIPT = path.join(__dirname, "..", "scripts", "install.sh");

// ─── Client detection ────────────────────────────────────────────────
function detectClients() {
  const clients = [];
  try {
    execFileSync("which", ["claude"], { stdio: "ignore" });
    clients.push({ id: "claude", label: "Claude Code", flag: "--claude" });
  } catch {}
  if (fs.existsSync(path.join(os.homedir(), ".codex"))) {
    clients.push({ id: "codex", label: "Codex CLI", flag: "--codex" });
  }
  if (fs.existsSync(path.join(os.homedir(), ".qoderwork"))) {
    clients.push({ id: "qoderwork", label: "QoderWork", flag: "--qoderwork" });
  }
  return clients;
}

// ─── TUI checkbox selector ──────────────────────────────────────────
//  ↑/↓  move   space  toggle   enter  confirm
function checkbox(title, items) {
  return new Promise((resolve) => {
    const selected = new Array(items.length).fill(true);
    let cursor = 0;

    const isTTY = process.stdin.isTTY && process.stdout.isTTY;
    if (!isTTY) {
      resolve(items.map((_, i) => i));
      return;
    }

    process.stdin.setRawMode(true);
    process.stdin.resume();
    process.stdin.setEncoding("utf8");

    const BLUE = "\x1b[34m";
    const GREEN = "\x1b[32m";
    const DIM = "\x1b[2m";
    const RESET = "\x1b[0m";
    const HIDE = "\x1b[?25l";
    const SHOW = "\x1b[?25h";
    const CHECKED = `${GREEN}◉${RESET}`;
    const UNCHECKED = `${DIM}○${RESET}`;

    function render() {
      // Move to start and clear
      process.stdout.write(`\x1b[${items.length + 2}A`);
      process.stdout.write("\x1b[J");
      draw();
    }

    function draw() {
      process.stdout.write(`${BLUE}?${RESET} ${title} ${DIM}(space=toggle, enter=confirm)${RESET}\n`);
      for (let i = 0; i < items.length; i++) {
        const pointer = i === cursor ? `${BLUE}❯${RESET}` : " ";
        const check = selected[i] ? CHECKED : UNCHECKED;
        process.stdout.write(`  ${pointer} ${check} ${items[i].label}\n`);
      }
      process.stdout.write(`\n`);
    }

    process.stdout.write(HIDE);
    draw();

    function onKey(key) {
      if (key === "\x03") {
        // Ctrl+C
        cleanup();
        process.stdout.write(SHOW);
        process.exit(130);
      }
      if (key === "\r") {
        // Enter
        cleanup();
        process.stdout.write(SHOW);
        const result = [];
        for (let i = 0; i < items.length; i++) {
          if (selected[i]) result.push(i);
        }
        resolve(result);
        return;
      }
      if (key === " ") {
        selected[cursor] = !selected[cursor];
        render();
        return;
      }
      // Arrow keys come as escape sequences
      if (key === "\x1b[A" || key === "k") {
        cursor = (cursor - 1 + items.length) % items.length;
        render();
        return;
      }
      if (key === "\x1b[B" || key === "j") {
        cursor = (cursor + 1) % items.length;
        render();
        return;
      }
      // 'a' to toggle all
      if (key === "a") {
        const allSelected = selected.every(Boolean);
        selected.fill(!allSelected);
        render();
        return;
      }
    }

    function cleanup() {
      process.stdin.setRawMode(false);
      process.stdin.pause();
      process.stdin.removeListener("data", onKey);
    }

    process.stdin.on("data", onKey);
  });
}

// ─── Main ────────────────────────────────────────────────────────────
async function main() {
  const args = process.argv.slice(2);
  const command = args[0];

  if (!command || command === "--help" || command === "-h") {
    console.log(`
  alibabacloud-agent-toolkit — one-command plugin installer

  Usage:
    npx alibabacloud-agent-toolkit install   [--claude] [--codex] [--qoderwork]
    npx alibabacloud-agent-toolkit uninstall [--claude] [--codex] [--qoderwork]

  Options:
    --claude      Claude Code only
    --codex       Codex CLI only
    --qoderwork   QoderWork only
    a             Toggle all
    (no flag = interactive client selection)
    `);
    process.exit(0);
  }

  if (command !== "install" && command !== "uninstall") {
    console.error(`Unknown command: ${command}\nRun with --help for usage.`);
    process.exit(1);
  }

  const flags = args.slice(1);
  const hasExplicitFlags = flags.some((f) =>
    ["--claude", "--codex", "--qoderwork"].includes(f)
  );

  if (!hasExplicitFlags) {
    const clients = detectClients();
    if (clients.length === 0) {
      console.error(
        "No supported AI coding client detected (Claude Code, Codex, QoderWork).\n" +
          "Install at least one, or specify --claude / --codex / --qoderwork."
      );
      process.exit(1);
    }

    const indices = await checkbox(
      `Which clients to ${command}?`,
      clients
    );

    if (indices.length === 0) {
      console.error("No client selected.");
      process.exit(1);
    }

    for (const i of indices) {
      flags.push(clients[i].flag);
    }
  }

  try {
    execFileSync("bash", [SCRIPT, command, ...flags], { stdio: "inherit" });
  } catch (e) {
    process.exit(e.status || 1);
  }
}

main();
