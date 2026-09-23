FROM alpine:3.20

RUN apk add --no-cache curl

COPY beacon.sh /beacon.sh
RUN chmod +x /beacon.sh

# 비-root 실행 (기존 데모 앱과 동일한 원칙 적용)
RUN adduser -D -u 1000 runner
USER runner

# checkov:skip=CKV_DOCKER_2: 5분 휴면 후 curl 한 번 보내고 종료하는 1회성 Job(Pod)이라
# 지속적으로 살아있는 프로세스가 아님 — HEALTHCHECK가 검증할 "떠 있는 상태" 자체가 없어
# 의미가 없다고 판단해 의도적으로 생략함 (receiver처럼 상시 서비스와는 성격이 다름)
CMD ["/beacon.sh"]
