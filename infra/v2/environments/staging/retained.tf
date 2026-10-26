# Keep the existing staging CloudFront migration-test entrypoint and its S3 assets in AWS.
# These have request/storage charges but no hourly ALB or cache charge.
removed {
  from = module.platform.aws_acm_certificate.cloudfront
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_acm_certificate_validation.cloudfront
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_cloudfront_cache_policy.images
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_cloudfront_cache_policy.static
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_cloudfront_distribution.web
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_cloudfront_key_group.images
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_cloudfront_origin_access_control.fe_static
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_cloudfront_origin_access_control.uploads
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_cloudfront_public_key.images
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_s3_bucket.fe_static
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_s3_bucket_public_access_block.fe_static
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_s3_bucket_policy.fe_static
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_s3_bucket.uploads
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_s3_bucket_public_access_block.uploads
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_s3_bucket_cors_configuration.uploads
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_s3_bucket_policy.uploads_cloudfront
  lifecycle { destroy = false }
}

removed {
  from = module.platform.aws_route53_record.alb_certificate
  lifecycle { destroy = false }
}
