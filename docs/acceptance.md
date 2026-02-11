# Acceptance Checklist

## DNS (Windows)

- `nslookup home.lan <AdGuard_IP>`
- `nslookup npm.lan <AdGuard_IP>`
- `nslookup adguard.lan <AdGuard_IP>`
- `nslookup pdf.lan <AdGuard_IP>`

## HTTP

- `curl -I http://home.lan`
- `curl -I http://npm.lan:81`
- `curl -I http://adguard.lan`
- `curl -I http://pdf.lan`
