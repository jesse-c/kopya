# Kopya

<!--toc:start-->
- [Intro](#intro)
- [Usage](#usage)
<!--toc:end-->

---

> [!WARNING]
> This is an alpha version. I am using it daily though.

---

## Intro

This is a headless/daemon-only clipboard manager[^1]. By itself, it's not useful, without a client.

It exposes a REST API over HTTP. You can list, search, and delete entries.

You can read my introductory blog post[^2]. The WIP (as of 2025-03-15) version of the Raycast extension is available too[^3].

## Usage

Use `$ just run`.

[^1]: https://j-e-s-s-e.com/blog/multi-uis-for-a-daemon-and-using-grpc-to-communicate-locally-from-rust-swift
[^2]: https://j-e-s-s-e.com/blog/alpha-release-of-kopya
[^3]: https://github.com/jesse-c/extensions/tree/feat/add-kopya/extensions/kopya
