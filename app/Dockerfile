# ---- 빌드 스테이지 ----
FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# ---- 최종 스테이지 ----
FROM node:20-alpine

# OS 패키지(OpenSSL 등) 최신 보안 패치 적용
RUN apk upgrade --no-cache

# base 이미지에 기본 포함된 npm/yarn CLI 제거
# - 런타임에 전혀 사용하지 않는데 취약점 스캔 결과에 노이즈를 만듦(예: node-tar CVE)
# - 이미지 용량도 줄어듦
RUN rm -rf /usr/local/lib/node_modules/npm \
    /usr/local/lib/node_modules/corepack \
    /opt/yarn-v* \
    /usr/local/bin/npm \
    /usr/local/bin/npx \
    /usr/local/bin/corepack

WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY package.json .
COPY app.js .

# 최소 권한 원칙 — root로 실행하지 않음 (박성현 Kyverno 정책과도 일치)
USER node

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://localhost:3000/health || exit 1

CMD ["node", "app.js"]
