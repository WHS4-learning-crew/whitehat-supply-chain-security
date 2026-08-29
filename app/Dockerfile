# ---- 빌드 스테이지 ----
FROM node:20-alpine AS builder
WORKDIR /app
COPY package.json .
RUN npm install --omit=dev

# ---- 최종 스테이지 ----
FROM node:20-alpine
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
