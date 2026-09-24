# ============================================
# A-1 시나리오 - Log4Shell(CVE-2021-44228) 재현용 테스트 이미지
# 담당: 조현서 / 4차 보고서 시나리오 검증용
#
# spring-boot-starter-log4j2(2.5.6)를 통해 log4j-core 2.14.1이
# "간접 의존성(transitive dependency)" 형태로 포함됨.
# pom.xml 어디에도 "log4j-core", "2.14.1"이라는 문구가 직접 선언되어 있지 않음
# → 실제 Log4Shell 사례의 핵심(숨겨진 간접 의존성)을 재현하기 위함
#
# 주의: 이 이미지는 실제 앱과 무관한 독립 테스트용이며,
#       workflow_dispatch로만 수동 실행됨 (main/feat 브랜치 자동 파이프라인과 분리)
# ============================================

FROM maven:3.8.4-eclipse-temurin-11 AS build

WORKDIR /build
COPY pom.xml .
COPY src ./src

# spring-boot-starter-log4j2 하나만으로 log4j-core:2.14.1, log4j-api:2.14.1이
# 자동으로 딸려옴 (직접 선언 없이)
RUN mvn clean package -DskipTests

FROM eclipse-temurin:11-jre-alpine
WORKDIR /app
COPY --from=build /build/target/*.jar app.jar

EXPOSE 8080
CMD ["java", "-jar", "app.jar"]
