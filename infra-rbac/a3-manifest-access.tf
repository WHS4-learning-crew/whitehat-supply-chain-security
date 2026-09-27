# A-3 정적 검사 전용: 업데이트 Manifest 저장소를 가정한 설정
# 실제 AWS에 적용하지 않음
resource "aws_s3_bucket" "a3_manifest" {
  bucket = "whs4-a3-manifest-demo-only"
}

resource "aws_s3_bucket_public_access_block" "a3_manifest" {
  bucket                  = aws_s3_bucket.a3_manifest.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_kms_key" "a3_manifest" {
  description         = "A-3 정적 검사 전용 키"
  enable_key_rotation = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "a3_manifest" {
  bucket = aws_s3_bucket.a3_manifest.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.a3_manifest.arn
      sse_algorithm     = "aws:kms"
    }
  }
}
