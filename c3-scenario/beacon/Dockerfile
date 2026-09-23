FROM alpine:3.20

RUN apk add --no-cache curl

COPY beacon.sh /beacon.sh
RUN chmod +x /beacon.sh

# 비-root 실행 (기존 데모 앱과 동일한 원칙 적용)
RUN adduser -D -u 1000 runner
USER runner

CMD ["/beacon.sh"]
