output "bucket_name" {
  description = "S3 bucket backing the snapshot repository"
  value       = aws_s3_bucket.snapshots.bucket
}

output "snapshot_repository" {
  description = "Elasticsearch snapshot repository name"
  value       = elasticstack_elasticsearch_snapshot_repository.s3.name
}

output "ilm_policy" {
  description = "ILM policy applied to logs, metrics and traces"
  value       = elasticstack_elasticsearch_index_lifecycle.demo.name
}
