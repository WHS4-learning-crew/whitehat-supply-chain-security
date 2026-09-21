// 시나리오 A-4 검증용 — gitleaks 탐지 테스트
// 실제 자격증명 아님, 테스트 후 브랜치 삭제 예정

const MONGO_URI = "mongodb://admin:TestPass123@db.internal.example:27017/prod";
const PG_URL = "postgresql://dbuser:PgTestPass99@postgres.internal:5432/appdb";
const REDIS_URL = "redis://:RedisTestPass77@redis.internal:6379/0";

module.exports = { MONGO_URI, PG_URL, REDIS_URL };
