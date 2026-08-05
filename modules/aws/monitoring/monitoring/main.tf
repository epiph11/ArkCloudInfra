resource "aws_sns_topic" "alerts" {
  name = "arkcloud-alerts-${var.name_prefix}"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  count = var.alarm_email != null ? 1 : 0

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

# ---------------------------------------------------------------------------
# Application-level exceptions — both apps log via Serilog's CompactJsonFormatter (see
# Program.cs in each), which omits "@l" entirely at Information level and sets it to
# "Warning"/"Error"/"Fatal" otherwise. These metric filters count Error/Fatal lines directly
# out of the same CloudWatch Logs groups already flowing from each ECS service — this is what
# actually answers the roadmap's "exceptions" monitoring requirement (Step 15), not just
# infrastructure-level resource metrics.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "api_errors" {
  name           = "arkcloud-${var.name_prefix}-api-errors"
  log_group_name = var.api_log_group_name
  pattern        = "{ $.@l = \"Error\" || $.@l = \"Fatal\" }"

  metric_transformation {
    name          = "ApiErrorCount"
    namespace     = "ArkCloud/${var.name_prefix}"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_log_metric_filter" "web_errors" {
  name           = "arkcloud-${var.name_prefix}-web-errors"
  log_group_name = var.web_log_group_name
  pattern        = "{ $.@l = \"Error\" || $.@l = \"Fatal\" }"

  metric_transformation {
    name          = "WebErrorCount"
    namespace     = "ArkCloud/${var.name_prefix}"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "api_errors" {
  alarm_name          = "arkcloud-${var.name_prefix}-api-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.api_errors.metric_transformation[0].name
  namespace           = aws_cloudwatch_log_metric_filter.api_errors.metric_transformation[0].namespace
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_description   = "ArkCloud.API logged an Error/Fatal-level event in the last 5 minutes."
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "web_errors" {
  alarm_name          = "arkcloud-${var.name_prefix}-web-errors"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = aws_cloudwatch_log_metric_filter.web_errors.metric_transformation[0].name
  namespace           = aws_cloudwatch_log_metric_filter.web_errors.metric_transformation[0].namespace
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_description   = "ArkCloud.Blazor logged an Error/Fatal-level event in the last 5 minutes."
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# ECS resource pressure — AWS/ECS namespace, no Container Insights required (works even if
# it's ever disabled). Threshold 85%, 2 consecutive 5-minute periods to avoid alarming on a
# brief deployment-time spike.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "api_cpu_high" {
  alarm_name          = "arkcloud-${var.name_prefix}-api-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  treat_missing_data  = "notBreaching"
  alarm_description   = "ArkCloud.API ECS task CPU above 85% for 10 minutes."
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.api_service_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "api_memory_high" {
  alarm_name          = "arkcloud-${var.name_prefix}-api-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  treat_missing_data  = "notBreaching"
  alarm_description   = "ArkCloud.API ECS task memory above 85% for 10 minutes."
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.api_service_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "web_cpu_high" {
  alarm_name          = "arkcloud-${var.name_prefix}-web-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  treat_missing_data  = "notBreaching"
  alarm_description   = "ArkCloud.Blazor ECS task CPU above 85% for 10 minutes."
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.web_service_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "web_memory_high" {
  alarm_name          = "arkcloud-${var.name_prefix}-web-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  treat_missing_data  = "notBreaching"
  alarm_description   = "ArkCloud.Blazor ECS task memory above 85% for 10 minutes."
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.web_service_name
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# ALB — target health (proxies "container restarts / deployment failures": a task that's
# crash-looping or failing its health check shows up here immediately) and 5xx rate.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "api_unhealthy" {
  alarm_name          = "arkcloud-${var.name_prefix}-api-unhealthy-targets"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_description   = "ArkCloud.API has at least one unhealthy target behind the ALB for 2 minutes straight."
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.api_target_group_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "web_unhealthy" {
  alarm_name          = "arkcloud-${var.name_prefix}-web-unhealthy-targets"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Average"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_description   = "ArkCloud.Blazor has at least one unhealthy target behind the ALB for 2 minutes straight."
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.web_target_group_arn_suffix
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "arkcloud-${var.name_prefix}-alb-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"
  alarm_description   = "More than 10 HTTP 5xx responses from ArkCloud targets in 5 minutes."
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# RDS — CPU, free storage, connection count. Thresholds sized for db.t3.micro (dev tier).
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "rds_cpu_high" {
  alarm_name          = "arkcloud-${var.name_prefix}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  alarm_description   = "RDS CPU above 80% for 10 minutes."
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_storage_low" {
  alarm_name          = "arkcloud-${var.name_prefix}-rds-storage-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 2147483648 # 2 GiB, in bytes — this metric is reported in bytes
  treat_missing_data  = "notBreaching"
  alarm_description   = "RDS free storage below 2 GiB."
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "rds_connections_high" {
  alarm_name          = "arkcloud-${var.name_prefix}-rds-connections-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseConnections"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 60 # db.t3.micro's default max_connections is well above this — early warning, not the hard ceiling
  treat_missing_data  = "notBreaching"
  alarm_description   = "RDS connection count above 60 for 10 minutes."
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBInstanceIdentifier = var.rds_instance_id
  }

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Dashboard — one place to see all of the above at a glance, matching the roadmap's explicit
# ask for CloudWatch Dashboards (Step 15), not just alarms.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "arkcloud-${var.name_prefix}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ECS CPU/Memory — API"
          view   = "timeSeries"
          region = "eu-west-1"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.api_service_name],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.api_service_name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "ECS CPU/Memory — Web"
          view   = "timeSeries"
          region = "eu-west-1"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.web_service_name],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.ecs_cluster_name, "ServiceName", var.web_service_name]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ALB — Requests & Response Time"
          view   = "timeSeries"
          region = "eu-west-1"
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "Average", yAxis = "right" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "ALB — Errors & Target Health"
          view   = "timeSeries"
          region = "eu-west-1"
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix, { stat = "Sum" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.api_target_group_arn_suffix, { stat = "Average" }],
            ["AWS/ApplicationELB", "UnHealthyHostCount", "LoadBalancer", var.alb_arn_suffix, "TargetGroup", var.web_target_group_arn_suffix, { stat = "Average" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "RDS"
          view   = "timeSeries"
          region = "eu-west-1"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds_instance_id],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.rds_instance_id, { yAxis = "right" }],
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.rds_instance_id, { yAxis = "right" }]
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 12
        width  = 12
        height = 6
        properties = {
          title  = "Application Errors (Serilog Error/Fatal)"
          view   = "timeSeries"
          region = "eu-west-1"
          metrics = [
            ["ArkCloud/${var.name_prefix}", "ApiErrorCount", { stat = "Sum" }],
            ["ArkCloud/${var.name_prefix}", "WebErrorCount", { stat = "Sum" }]
          ]
        }
      }
    ]
  })
}
