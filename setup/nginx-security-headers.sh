#!/bin/sh
# nginx hardening for DS218+ DSM
# Generates http.rate-limit.conf (http context) and dsm.hardening.conf (server context).
# Idempotent — overwrites on each run.

NGINX_CONFD="/etc/nginx/conf.d"

# =============================================================================
# http.rate-limit.conf — rate limit zones (http context)
# =============================================================================

cat > "$NGINX_CONFD/http.rate-limit.conf" << 'EOF'
# map: only /webapi/auth.cgi gets a rate-limit key; everything else gets empty key (= no limit)
# nginx skips rate limiting when key is ""; Photos/Drive are not affected
map $request_uri $dsm_auth_limit_key {
    ~^/webapi/auth\.cgi  $binary_remote_addr;
    default              "";
}
limit_req_zone $dsm_auth_limit_key zone=dsm_login:10m rate=10r/m;
EOF

# =============================================================================
# dsm.hardening.conf — security headers + rate limit + access log (server context)
# =============================================================================

cat > "$NGINX_CONFD/dsm.hardening.conf" << 'EOF'
# Security headers
add_header X-Content-Type-Options  "nosniff"                    always;
add_header X-Frame-Options         "SAMEORIGIN"                 always;
add_header X-XSS-Protection        "1; mode=block"              always;
add_header Referrer-Policy         "strict-origin-when-cross-origin" always;
add_header X-Robots-Tag            "noindex, nofollow"          always;

# HSTS — applies on DSM HTTPS port and :443
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

# Access log in combined format
access_log /var/log/nginx/access.log combined;

# Rate limiting — only /webapi/auth.cgi (empty key = no limit for everything else)
limit_req zone=dsm_login burst=5 nodelay;
limit_req_status 429;
EOF

# =============================================================================
# Reload nginx if generated config is valid
# =============================================================================

if nginx -t -q 2>/dev/null; then
    nginx -s reload 2>/dev/null
    exit 0
else
    nginx -t 2>&1
    exit 1
fi
