# Good to note

A personal iOS expense-tracking (记账) app that keeps all of your financial data on your device.

Good to note is built around one idea: **make recording a transaction as low-friction as possible**, so the ledger actually stays up to date. It combines quick manual entry, recurring rules, and optional low-friction auto-capture — while keeping everything local, private, and account-free.

---

## Features

- **Fast manual entry** — a focused, keyboard-first flow for logging a transaction in seconds.
- **Recurring transactions** — define a rule once (rent, subscriptions, salary) and let it post on schedule.
- **Low-friction auto-capture** — instead of retyping, let iOS help. Using the **Shortcuts** app's automations, incoming signals can be routed into the app:
  - bank **SMS** notifications,
  - **Apple Pay** / Wallet transaction notifications,
  - bank **email** receipts.

  Each automation hands its text to the app through an **App Intent**, which parses the amount, currency, and merchant and writes a draft entry into your local ledger for you to confirm. Setup is guided in-app, and you stay in control of what gets recorded.
- **Multi-currency** — track spending across currencies with a configurable **base currency** (defaults to **SGD**). Exchange rates are fetched on demand and cached on device, with a graceful fallback when the network is unavailable.
- **Backups you own** — the app keeps a database backup inside its own storage, exposed through the iOS **Files** app so you can copy it wherever you like. Nothing is uploaded.
- **Bilingual** — full **English / 简体中文** UI that follows your system language.

## Privacy

Your financial data stays on your device.

- **No accounts, no login, no servers.** The app has no way to identify you.
- **No analytics, no advertising, no tracking, no third-party SDKs.**
- **The only network connection** is a currency-rate lookup that sends *only* a three-letter currency code (e.g. `SGD`) to a public exchange-rate service. It uses **no API key** and carries none of your data.

Full details, in English and 简体中文, are in **[PRIVACY.md](PRIVACY.md)**.

## Tech

- **SwiftUI** + **SwiftData**
- **iOS 17+**
- **App Intents** for the Shortcuts-based auto-capture flows
- No third-party dependencies

## Build & run

1. Open `GoodToNote.xcodeproj` in Xcode (a recent version supporting the iOS 17 SDK).
2. Select an iOS 17+ simulator or device and run.

No API keys or configuration are required.

---

## 简体中文

**Good to note** 是一款个人 iOS 记账应用,所有财务数据都只保存在你的设备上。

核心理念是**尽量降低记一笔账的成本**,让账本真正保持更新。它把快速手动记账、周期规则,以及可选的低成本自动捕捉结合在一起,同时保持全部数据本地化、隐私、无需账号。

**主要功能**

- **快速手动记账**——以键盘优先的简洁流程,几秒钟记完一笔。
- **周期交易**——房租、订阅、工资等只需设定一次规则,即可按计划自动记入。
- **低成本自动捕捉**——借助 iOS **快捷指令(Shortcuts)** 的自动化,把银行**短信**、**Apple Pay** / 钱包交易通知、银行**邮件**回执的文本交给应用;应用通过 **App Intent** 解析金额、币种与商户,生成一条草稿待你确认。应用内提供分步引导,记什么由你决定。
- **多币种**——支持多币种记账,本位币可配置(默认 **SGD**);汇率按需获取并本地缓存,断网时优雅回退。
- **你掌控的备份**——数据库备份保存在应用自身存储区,并通过 iOS**「文件」**应用开放给你自行拷贝,绝不上传。
- **中英双语**——完整 **简体中文 / English** 界面,跟随系统语言。

**隐私**

你的财务数据只保存在你的设备上:没有账号、没有服务器、没有分析统计/广告/追踪、没有第三方 SDK。唯一的联网是获取汇率——只发送一个三位货币代码(如 `SGD`),不使用任何 API 密钥,也不携带你的任何数据。完整政策见 **[PRIVACY.md](PRIVACY.md)**。

**技术栈**:SwiftUI + SwiftData,iOS 17+,使用 App Intents 支撑快捷指令自动捕捉;无第三方依赖。

**构建运行**:用 Xcode 打开 `GoodToNote.xcodeproj`,选择 iOS 17+ 的模拟器或真机运行,无需任何密钥或额外配置。
