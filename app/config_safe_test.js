// 오탐 검증용 — 탐지되면 안 되는 케이스들
const MONGO_FROM_ENV = process.env.MONGO_URI;
const PG_FROM_ENV = process.env.DATABASE_URL;

const REDIS_TEMPLATE = "redis://:${REDIS_PASSWORD}@redis:6379/0";
const LOCAL_DEV = "postgresql://devuser:devpass@localhost:5432/devdb";
const DOC_EXAMPLE = "mongodb://username:your-password-here@example.com:27017/mydb";
const PLACEHOLDER = "mysql://user:<PASSWORD>@db.host:3306/schema";
