# GuardDuty — équivalent AWS de Microsoft Defender for Cloud (Azure, modules/azure/defender).
#
# Le détecteur de base (ci-dessous) analyse déjà, sans configuration supplémentaire ni coût
# additionnel au-delà du détecteur lui-même : les événements de gestion CloudTrail, les flow
# logs VPC, et les requêtes DNS. Volontairement PAS activés ici : S3 Protection, EKS Protection,
# Malware Protection, RDS Protection, Lambda Protection — ce sont des sources de données payantes
# séparément, pertinentes une fois qu'il y a vraiment des buckets S3 applicatifs, un cluster EKS
# ou des instances RDS exposées à un vecteur d'attaque que ces add-ons couvrent spécifiquement.
# Rien de tout ça n'existe encore dans ArkCloud (Sprint 8/9 pour EKS-like, aucun S3 applicatif).
# À reconsidérer add-on par add-on quand la brique qu'il protège existe réellement.
resource "aws_guardduty_detector" "this" {
  enable                       = true
  finding_publishing_frequency = var.finding_publishing_frequency

  tags = var.tags
}

# GuardDuty ne pousse ses findings nulle part par lui-même — contrairement aux CloudWatch Alarms
# (modules/aws/monitoring, modules/aws/secret-rotation) qui ciblent SNS directement, un finding
# GuardDuty est un événement EventBridge, pas une métrique. EventBridge est le pont standard AWS
# entre les deux mondes.
#
# Filtré à >= var.min_severity_for_alert : voir variables.tf pour pourquoi Low est exclu par défaut.
resource "aws_cloudwatch_event_rule" "findings" {
  name        = "arkcloud-guardduty-findings-${var.name_prefix}"
  description = "Route les findings GuardDuty (sévérité >= ${var.min_severity_for_alert}) vers le topic SNS d'alertes."

  event_pattern = jsonencode({
    source      = ["aws.guardduty"]
    detail-type = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", var.min_severity_for_alert] }]
    }
  })

  tags = var.tags
}

# input_transformer plutôt que le JSON brut du finding : ce dernier est profondément imbriqué
# (resource, service, additionalInfo...) et illisible dans un email ou un SMS. Ces cinq champs
# suffisent à une première décision — même arbitrage que l'alarme CloudWatch de secret-rotation
# (nom de métrique clair plutôt que le payload complet de la fonction).
resource "aws_cloudwatch_event_target" "findings_to_sns" {
  rule      = aws_cloudwatch_event_rule.findings.name
  target_id = "sns-alerts"
  arn       = var.alarm_sns_topic_arn

  input_transformer {
    input_paths = {
      type     = "$.detail.type"
      severity = "$.detail.severity"
      title    = "$.detail.title"
      account  = "$.account"
      region   = "$.region"
    }
    input_template = "\"GuardDuty (<severity>) — <type> : <title> — compte <account>, region <region>\""
  }
}
