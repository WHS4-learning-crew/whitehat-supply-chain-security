FROM nginxinc/nginx-unprivileged:1.27-alpine

# nginx-unprivileged 이미지는 기본적으로 비-root(UID 101, nginx 계정)로 실행되고
# 1024 이하 포트를 못 열기 때문에, 우리도 8080(비특권 포트) 사용
COPY nginx.conf /etc/nginx/nginx.conf

# 베이스 이미지가 내부적으로 비-root로 전환되지만, Checkov(CKV_DOCKER_3)가
# 정적으로 확인할 수 있도록 명시적으로 USER 선언
USER nginx

EXPOSE 8080

# receiver는 계속 떠 있는 서버이므로 헬스체크로 살아있는지 주기 확인
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://localhost:8080/beacon || exit 1

CMD ["nginx", "-g", "daemon off;"]
