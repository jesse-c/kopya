# Kopya

<!--toc:start-->
- [Intro](#intro)
- [Features](#features)
- [Config](#config)
  - [Regex Filtering](#regex-filtering)
- [Install](#install)
- [Clients](#clients)
<!--toc:end-->

---

> [!WARNING]
> This is an alpha version. I am using it daily though.

---

## Intro

This is a headless/daemon-only clipboard manager[^1]. By itself, it's not useful, without a [client](#clients).

It exposes a REST API over HTTP. You can list, search, and delete entries.

You can read my introductory blog post[^2].

## Features

- Store your clipboard entries over time
- Limit how many are stored, with a rolling clean-up window
- Private Mode: Disable clipboard monitoring, and optionally re-enable after a set time, or at and end time
- Content filtering: Skip storing sensitive data matching regex patterns
- Optional: Run at login
- Optional: Backup hourly

## Config

There must be a config file at `$USER/.config/kopya/config.toml`, with contents like the following:

```toml
run-at-login = true
max-entries = 10000000
port = 9090
backup = true
filter = true
filters = [
  "password\\w*",
  ".*token.*",
  ".*api_?key.*",
  ".*secret.*",
  "\\b\\d{4}[- ]?\\d{4}[- ]?\\d{4}[- ]?\\d{4}\\b"  # Credit card pattern
]
```

### Regex Filtering

Kopya supports filtering clipboard content based on Swift's native Regex patterns. When enabled, any clipboard content matching one of your filter patterns will be detected but not stored, helping protect sensitive information.

- Enable filtering with `filter = true`
- Define patterns with `filters = [...]`
- If `filter = true` but no filters are provided, no content will be filtered

## Install

Use `$ just version release install` or download a [release](https://github.com/jesse-c/kopya/releases/latest).

## Clients

- Raycast extension: [WIP](https://github.com/jesse-c/extensions/tree/feat/add-kopya/extensions/kopya)
- Emacs package: [WIP](https://github.com/jesse-c/dotfiles/blob/main/home/dot_config/emacs/user/kopya.el)

[^1]: https://j-e-s-s-e.com/blog/multi-uis-for-a-daemon-and-using-grpc-to-communicate-locally-from-rust-swift
[^2]: https://j-e-s-s-e.com/blog/alpha-release-of-kopya
