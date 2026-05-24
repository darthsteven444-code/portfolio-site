# steven-garcia.dev

Personal portfolio site — built with [Astro](https://astro.build/) and [Tailwind CSS](https://tailwindcss.com/), self-hosted on a homelab Ubuntu Server VM behind nginx and Cloudflare.

## Stack

- **Framework:** Astro 5 (static site generation, zero JavaScript shipped by default)
- **Styling:** Tailwind CSS v4 + `@tailwindcss/typography`
- **Content:** Markdown via Astro Content Collections
- **Hosting:** Self-hosted on Ubuntu Server 24.04, served by nginx
- **CDN / WAF / TLS:** Cloudflare
- **Monitoring:** Prometheus + `blackbox_exporter` + Grafana dashboard with Discord alerting

## Local development

```bash
npm install
npm run dev -- --host 0.0.0.0
```

Site is served at `http://localhost:4321`.

## Build

```bash
npm run build
```

Static output lands in `./dist/` — deploy that directory to any static host.

## Project structure

```
src/
├── content/projects/       # project writeups in markdown
├── layouts/Base.astro      # shared page wrapper
├── pages/
│   ├── index.astro         # home page
│   └── projects/[...slug]  # dynamic project routes
└── styles/global.css         # Tailwind import
```
