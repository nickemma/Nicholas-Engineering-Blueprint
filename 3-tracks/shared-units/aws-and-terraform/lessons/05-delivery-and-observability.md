# 05 Exercise queue delivery and observe failures

The independent SQS consumer handles a single synthetic notice per run. Core 03's jobs remain owned by the durable PostgreSQL coordinator. Use the AWS SDK with a local transport fixture to inspect the requests. Return an error before deleting the receipt when the handler fails. Simulate a redelivery with a different receipt and verify that only this successful attempt deletes it.

Read the CloudWatch alarms for the API, database, and dead-letter queue. Forecast and actual budget notifications warn the operator so they can act. Cost continues to depend on actual provisioned resources and usage.

### alarms.tf

Create `infra/alarms.tf`.

<!-- file: infra/alarms.tf -->
~~~hcl
# Step 10's alerts, in CloudWatch, sent by email through an SNS topic.
resource "aws_sns_topic" "alarms" {
  name = "switchyard-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alert_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email" # AWS emails a link; nothing arrives until you click it
  endpoint  = var.alert_email
}

# The fast burn: over 1.44% of requests failing (14.4 times the 0.1%
# budget) in each of two 5-minute periods.
resource "aws_cloudwatch_metric_alarm" "api_errors" {
  alarm_name          = "switchyard-api-error-budget-burn"
  alarm_description   = "Over 1.44% of API requests are failing. "
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0.0144
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching" # no traffic is not an outage
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { LoadBalancer = aws_lb.main.arn_suffix }
      period      = 300
      stat        = "Sum"
    }
  }
  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      dimensions  = { LoadBalancer = aws_lb.main.arn_suffix }
      period      = 300
      stat        = "Sum"
    }
  }
  metric_query {
    id          = "ratio"
    expression  = "errors / requests"
    label       = "Share of requests failing"
    return_data = true
  }
}

# Any dead-lettered message (the game day's finding).
resource "aws_cloudwatch_metric_alarm" "dead_letters" {
  for_each            = aws_sqs_queue.dead
  alarm_name          = "switchyard-dead-letters-${each.key}"
  alarm_description   = "Messages wait in ${each.value.name}. Read them, fix the cause, then redrive or discard them."
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value.name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

# The database running out of CPU or disk.
resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  alarm_name          = "switchyard-db-cpu"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "db_storage" {
  alarm_name          = "switchyard-db-storage"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.main.identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 2 * 1024 * 1024 * 1024 # 2 GiB
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

# A cloud account bills by the hour whether you are using it or not. This
# emails you before a forgotten "terraform destroy" becomes expensive.
resource "aws_budgets_budget" "monthly" {
  count        = var.alert_email == "" ? 0 : 1
  name         = "switchyard-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}
~~~

### go.mod

Create `queue/go.mod`.

<!-- file: queue/go.mod -->
~~~text
module switchyard/cloud

go 1.26.6

require (
	github.com/aws/aws-sdk-go-v2 v1.47.1
	github.com/aws/aws-sdk-go-v2/config v1.33.7
	github.com/aws/aws-sdk-go-v2/service/sqs v1.52.2
)

require (
	github.com/aws/aws-sdk-go-v2/credentials v1.20.7 // indirect
	github.com/aws/aws-sdk-go-v2/feature/ec2/imds v1.20.1 // indirect
	github.com/aws/aws-sdk-go-v2/internal/configsources v1.5.4 // indirect
	github.com/aws/aws-sdk-go-v2/internal/endpoints/v2 v2.8.4 // indirect
	github.com/aws/aws-sdk-go-v2/internal/v4a v1.5.4 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/accept-encoding v1.13.19 // indirect
	github.com/aws/aws-sdk-go-v2/service/internal/presigned-url v1.14.4 // indirect
	github.com/aws/aws-sdk-go-v2/service/signin v1.10.2 // indirect
	github.com/aws/aws-sdk-go-v2/service/sso v1.38.2 // indirect
	github.com/aws/aws-sdk-go-v2/service/ssooidc v1.43.2 // indirect
	github.com/aws/aws-sdk-go-v2/service/sts v1.51.2 // indirect
	github.com/aws/smithy-go v1.28.1 // indirect
)
~~~

### go.sum

Create `queue/go.sum`.

<!-- file: queue/go.sum -->
~~~text
github.com/aws/aws-sdk-go-v2 v1.47.1 h1:uOIZnp4PK3ZhKI0dNrJrhTEsLxbpXHTAJlwoS1pvAtw=
github.com/aws/aws-sdk-go-v2 v1.47.1/go.mod h1:bttEH6JqnUL8LepvDVfdrds/fZ5bCIxzpe3abyUrhDU=
github.com/aws/aws-sdk-go-v2/config v1.33.7 h1:vgG8uuhm7vNsxr6BsXNG+Ciesh9iLdNPzarAAu/dB6A=
github.com/aws/aws-sdk-go-v2/config v1.33.7/go.mod h1:5KWNY38altxnd5cxcNoOTrFtJ7asFEiCiWfb2m+M2pE=
github.com/aws/aws-sdk-go-v2/credentials v1.20.7 h1:mit8rRVnmt+wvT4U6putiWSlwe3eKD2n6ElgyfcP/Mw=
github.com/aws/aws-sdk-go-v2/credentials v1.20.7/go.mod h1:/2pPi2qhPug21z6l3M0+AKUqAT1zn2MhRCtnQv8R5Zg=
github.com/aws/aws-sdk-go-v2/feature/ec2/imds v1.20.1 h1:8gALAAmacnIXh+z6VkdDanv4/IkG5APdg4DZLDTmLog=
github.com/aws/aws-sdk-go-v2/feature/ec2/imds v1.20.1/go.mod h1:Z7IJhJU+poOdJjUR2wpyY21ossQ1XS/R3Lk9Msq5kM4=
github.com/aws/aws-sdk-go-v2/internal/configsources v1.5.4 h1:CLq4+8UHCI+ZZYl/EuJxXovaIVN2xeeT8JV+dsApQ5E=
github.com/aws/aws-sdk-go-v2/internal/configsources v1.5.4/go.mod h1:Wv4q5sAM04xAMkoOedxLx2inVf6K5FdxYp+A61L+q/0=
github.com/aws/aws-sdk-go-v2/internal/endpoints/v2 v2.8.4 h1:dD4MR81I7YkpEBRk6UP9rocC2QnT3qVuXwzlYTtfGEs=
github.com/aws/aws-sdk-go-v2/internal/endpoints/v2 v2.8.4/go.mod h1:EcXV1kAFd5XwSkDHlj94gnF3q5CkJyYiIJfH8N0VmrE=
github.com/aws/aws-sdk-go-v2/internal/v4a v1.5.4 h1:7Wo47d/xn/7KttCSBd8EGYeZ7ULRFRkUHr6vkZPBzVQ=
github.com/aws/aws-sdk-go-v2/internal/v4a v1.5.4/go.mod h1:tDB2IVC1xC3vX8o+6uRlzhTxP3g1b77CZXFX/oD2FnQ=
github.com/aws/aws-sdk-go-v2/service/internal/accept-encoding v1.13.19 h1:bAdDl/HkGCcGPoe25ToSHEw23VIxt6CT5fLcg111BKg=
github.com/aws/aws-sdk-go-v2/service/internal/accept-encoding v1.13.19/go.mod h1:KaUzbLxv4CeSxh6ZCl9B4m7CuFenS8kUEaDs+f/DQr4=
github.com/aws/aws-sdk-go-v2/service/internal/presigned-url v1.14.4 h1:29SvnfGhXjTl8ONxFwbj2rs6lbhiFXD2CgFQmbT/bXY=
github.com/aws/aws-sdk-go-v2/service/internal/presigned-url v1.14.4/go.mod h1:wm04I5DMuNVvZHFe/dHnUxincvNbbK7AiNBbYsQivek=
github.com/aws/aws-sdk-go-v2/service/signin v1.10.2 h1:vrPP4O9VABnquYrDHfU+Fu0Fp6TuzaqPUu9Fh7VBBVY=
github.com/aws/aws-sdk-go-v2/service/signin v1.10.2/go.mod h1:xpo/geVldu8payT375WekctUzopG/hBU7miiqItMUlw=
github.com/aws/aws-sdk-go-v2/service/sqs v1.52.2 h1:6ZXe/lG2mbGhw10y/aiKbe/poytLoYJsdbKV1pT9+ws=
github.com/aws/aws-sdk-go-v2/service/sqs v1.52.2/go.mod h1:+TDqZ1h8CLkW9ewfQkSPWHYRjm7/wDThKeDlR46qyvE=
github.com/aws/aws-sdk-go-v2/service/sso v1.38.2 h1:I8F/K5ahKJ4npqeGBBmMPftQy3/o1A55VRq2eUcP9Ts=
github.com/aws/aws-sdk-go-v2/service/sso v1.38.2/go.mod h1:rRD/dnm7q0HYE/I5TMaPgkWyyUGLcwuxHLABsLnQ3e0=
github.com/aws/aws-sdk-go-v2/service/ssooidc v1.43.2 h1:i5nn7Ri5CgFfNRzwlUiZOIIUA+5Vgg+unNEC0PzF1+s=
github.com/aws/aws-sdk-go-v2/service/ssooidc v1.43.2/go.mod h1:skwM/xsbR/1ReUTesv9BhpJp1VjajR7DWQnuVLwiXsQ=
github.com/aws/aws-sdk-go-v2/service/sts v1.51.2 h1:AWSPqynwEJV8J2pl/p7aizCf7a23/NGHR+rK/KLOxi4=
github.com/aws/aws-sdk-go-v2/service/sts v1.51.2/go.mod h1:26zA0GhDrLo+yiLI2yXWxqB1PdsShfLikoI7GOEgugM=
github.com/aws/smithy-go v1.28.1 h1:R/nXH00c8qcfCzQVELtRw+eLQWtzv+VAIEFJ1/xxXlQ=
github.com/aws/smithy-go v1.28.1/go.mod h1:YE2RhdIuDbA5E5bTdciG9KrW3+TiEONeUWCqxX9i1Fc=
~~~

### delivery.go

Create `queue/internal/sqsprobe/delivery.go`.

<!-- file: queue/internal/sqsprobe/delivery.go -->
~~~go
// Package sqsprobe exercises receive and delete for an independent delivery queue.
package sqsprobe

import (
	"context"
	"errors"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
)

func Once(ctx context.Context, client *sqs.Client, queue string, handle func(string) error) (bool, error) {
	out, err := client.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
		QueueUrl: &queue, MaxNumberOfMessages: 1, WaitTimeSeconds: 5,
	})
	if err != nil {
		return false, err
	}
	if len(out.Messages) == 0 {
		return false, nil
	}
	delivery := out.Messages[0]
	if delivery.ReceiptHandle == nil || delivery.Body == nil {
		return true, errors.New("missing SQS receipt or body")
	}
	if err := handle(aws.ToString(delivery.Body)); err != nil {
		return true, fmt.Errorf("handler left delivery unacknowledged: %w", err)
	}
	_, err = client.DeleteMessage(ctx, &sqs.DeleteMessageInput{QueueUrl: &queue, ReceiptHandle: delivery.ReceiptHandle})
	return true, err
}
~~~

### delivery_test.go

Create `queue/internal/sqsprobe/delivery_test.go`.

<!-- file: queue/internal/sqsprobe/delivery_test.go -->
~~~go
package sqsprobe

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
)

type fixtureTransport func(*http.Request) (*http.Response, error)

func (f fixtureTransport) Do(r *http.Request) (*http.Response, error) { return f(r) }

func TestFailedHandlerKeepsMessage(t *testing.T) {
	var mu sync.Mutex
	receives, deletes := 0, 0
	var issues []string
	fixture := fixtureTransport(func(r *http.Request) (*http.Response, error) {
		w := httptest.NewRecorder()
		mu.Lock()
		defer mu.Unlock()
		w.Header().Set("Content-Type", "application/x-amz-json-1.0")
		switch r.Header.Get("X-Amz-Target") {
		case "AmazonSQS.ReceiveMessage":
			receives++
			fmt.Fprintf(w, `{"Messages":[{"MessageId":"job-notice","Body":"fixture","ReceiptHandle":"delivery-%d"}]}`, receives)
		case "AmazonSQS.DeleteMessage":
			deletes++
			var req struct{ ReceiptHandle string }
			if json.NewDecoder(r.Body).Decode(&req) != nil || req.ReceiptHandle != "delivery-2" {
				issues = append(issues, "expected the receipt from the successful retry")
			}
			fmt.Fprint(w, "{}")
		default:
			issues = append(issues, "unexpected SQS action")
			w.WriteHeader(http.StatusBadRequest)
		}
		return w.Result(), nil
	})
	endpoint := "http://fixture.invalid"
	client := sqs.New(sqs.Options{Region: "us-east-1", BaseEndpoint: &endpoint, Credentials: aws.AnonymousCredentials{}, HTTPClient: fixture})
	fail := errors.New("temporary failure")
	if got, err := Once(context.Background(), client, endpoint+"/queue", func(string) error { return fail }); !got || !errors.Is(err, fail) {
		t.Fatalf("first attempt: %t %v", got, err)
	}
	mu.Lock()
	deletedTooEarly := deletes != 0
	mu.Unlock()
	if deletedTooEarly {
		t.Fatal("failed handler deleted the message")
	}
	if _, err := Once(context.Background(), client, endpoint+"/queue", func(body string) error {
		if body != "fixture" {
			return errors.New("body changed")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if receives != 2 || deletes != 1 || len(issues) != 0 {
		t.Fatal(receives, deletes, issues)
	}
	t.Log("failed handler kept the message eligible for redelivery; success deleted the second receipt")
}
~~~

### main.go

Create `queue/cmd/cloud-delivery/main.go`.

<!-- file: queue/cmd/cloud-delivery/main.go -->
~~~go
package main

import (
	"context"
	"errors"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
	"switchyard/cloud/internal/sqsprobe"
)

func run(ctx context.Context) error {
	queue := os.Getenv("DELIVERY_QUEUE_URL")
	if queue == "" {
		return errors.New("DELIVERY_QUEUE_URL is required")
	}
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return err
	}
	poll, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	received, err := sqsprobe.Once(poll, sqs.NewFromConfig(cfg), queue, func(body string) error {
		if body != "switchyard-delivery-check" {
			return errors.New("unsupported lab notice")
		}
		log.Print("processed synthetic delivery notice")
		return nil
	})
	if err != nil {
		return err
	}
	if !received {
		log.Print("no message before the long poll expired")
	}
	return nil
}
func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := run(ctx); err != nil {
		log.Fatal(err)
	}
}
~~~

## Check it

~~~bash
(cd queue && go vet ./... && go test -race -count=1 -v ./...)
~~~

<!-- run: (cd queue && go vet ./... && go test -race -count=1 -v ./...) -->
