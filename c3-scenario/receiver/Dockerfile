FROM nginxinc/nginx-unprivileged:1.27-alpine

# nginx-unprivileged 이미지는 기본적으로 비-root(UID 101, nginx 계정)로 실행되고
# 1024 이하 포트를 못 열기 때문에, 우리도 8080(비특권 포트) 사용
COPY nginx.conf /etc/nginx/nginx.conf

EXPOSE 8080

CMD ["nginx", "-g", "daemon off;"]
