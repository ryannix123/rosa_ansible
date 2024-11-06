#!/bin/bash

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color
BOLD='\033[1m'

echo -e "${BOLD}Discovering AWS services in use...${NC}"

# Initialize arrays to store services
services=()
costs=()
resource_ids=()

# Check AWS CLI credentials
if ! aws sts get-caller-identity &>/dev/null; then
    echo -e "${RED}Error: AWS credentials not configured. Please run 'aws configure' first.${NC}"
    exit 1
fi

# Get current region
current_region=$(aws configure get region)
if [ -z "$current_region" ]; then
    current_region="us-east-1"  # Default to us-east-1 if not set
fi

echo -e "${GREEN}Scanning region: $current_region${NC}"

# Function to add service to our tracking array
add_service() {
    local service=$1
    local service_key=$2
    local resource_id=$3
    # Check if service is already in array to avoid duplicates
    if [[ ! " ${services[@]} " =~ " ${service} " ]]; then
        services+=("$service")
        costs+=("$service_key")
        resource_ids+=("$resource_id")
    fi
}

# Function to get AWS console URL
get_console_url() {
    local service=$1
    local region=$2
    
    case "$service" in
        "EC2")
            echo "https://${region}.console.aws.amazon.com/ec2/home?region=${region}#Instances:"
            ;;
        "VPC")
            echo "https://${region}.console.aws.amazon.com/vpc/home?region=${region}#vpcs:"
            ;;
        "ELB")
            echo "https://${region}.console.aws.amazon.com/ec2/home?region=${region}#LoadBalancers:"
            ;;
        "Lightsail")
            echo "https://${region}.console.aws.amazon.com/lightsail/home?region=${region}"
            ;;
        "Route53")
            echo "https://console.aws.amazon.com/route53/home#hosted-zones:"
            ;;
        "S3")
            echo "https://s3.console.aws.amazon.com/s3/home?region=${region}"
            ;;
        *)
            echo "https://console.aws.amazon.com"
            ;;
    esac
}

# Function to display deletion requirements
display_deletion_info() {
    local service=$1
    local region=$2
    
    echo -e "\n${BOLD}Deletion Requirements for ${service}:${NC}"
    
    case "$service" in
        "EC2 (Elastic Compute Cloud)")
            echo -e "${YELLOW}Requirements:${NC}"
            echo "- Terminate instances via CLI or console"
            echo "- Delete EBS volumes after instance termination"
            echo "- Release Elastic IPs separately"
            echo "- Security groups must have no dependencies"
            echo -e "\n${YELLOW}Dependencies to check:${NC}"
            echo "- Running instances"
            echo "- Attached EBS volumes"
            echo "- Load balancer connections"
            echo "- Security group rules"
            echo -e "\n${YELLOW}Console URL:${NC}"
            echo "$(get_console_url "EC2" $region)"
            ;;
        "VPC (Virtual Private Cloud)")
            echo -e "${RED}WARNING: Complex service with many dependencies${NC}"
            echo -e "${YELLOW}Requirements:${NC}"
            echo "- Must be done through console for safety"
            echo "- Default VPC cannot be deleted without AWS support"
            echo "- All resources in VPC must be terminated first"
            echo -e "\n${YELLOW}Dependencies to check:${NC}"
            echo "- EC2 instances"
            echo "- RDS instances"
            echo "- Load balancers"
            echo "- NAT gateways"
            echo "- VPC endpoints"
            echo -e "\n${YELLOW}Console URL:${NC}"
            echo "$(get_console_url "VPC" $region)"
            ;;
        *)
            echo -e "${YELLOW}Please check AWS Console for specific requirements${NC}"
            echo "$(get_console_url "$service" $region)"
            ;;
    esac
}

# Simple date calculation for current month
month=$(date "+%m")
year=$(date "+%Y")
start_date="$year-$month-01"
if [[ "$month" == "12" ]]; then
    end_date="$year-12-31"
else
    next_month=$((month + 1))
    end_date="$year-$(printf "%02d" $next_month)-01"
fi

# Check for common AWS services
echo -e "${BOLD}Checking for active services...${NC}"

# EC2
if aws ec2 describe-instances --region $current_region --output text 2>/dev/null | grep -q .; then
    add_service "EC2 (Elastic Compute Cloud)" "Amazon Elastic Compute Cloud" "ec2"
fi

# VPC
if aws ec2 describe-vpcs --region $current_region --output text 2>/dev/null | grep -q .; then
    add_service "VPC (Virtual Private Cloud)" "Amazon Virtual Private Cloud" "vpc"
fi

# Elastic Load Balancing
if aws elbv2 describe-load-balancers --region $current_region --output text 2>/dev/null | grep -q . || \
   aws elb describe-load-balancers --region $current_region --output text 2>/dev/null | grep -q .; then
    add_service "Elastic Load Balancing" "Amazon Elastic Load Balancing" "elb"
fi

# Lightsail
if aws lightsail get-instances --region $current_region --output text 2>/dev/null | grep -q .; then
    add_service "Lightsail" "Amazon Lightsail" "lightsail"
fi

# Route 53
if aws route53 list-hosted-zones --output text 2>/dev/null | grep -q .; then
    add_service "Route 53" "Amazon Route 53" "route53"
fi

# S3
if aws s3 ls &>/dev/null; then
    add_service "S3" "Amazon Simple Storage Service" "s3"
fi

# Print results with costs
echo -e "\n${BOLD}Active AWS services detected:${NC}"

# Get all costs at once for better performance
all_costs=$(aws ce get-cost-and-usage \
    --time-period Start=$start_date,End=$end_date \
    --granularity MONTHLY \
    --metrics "UnblendedCost" \
    --group-by Type=DIMENSION,Key=SERVICE \
    --output json)

# Display services with numbers for selection
for i in "${!services[@]}"; do
    service=${services[$i]}
    service_key=${costs[$i]}
    
    # Extract cost from the JSON response
    cost=$(echo "$all_costs" | jq -r --arg svc "$service_key" '.ResultsByTime[].Groups[] | select(.Keys[0] | contains($svc)) | .Metrics.UnblendedCost.Amount // empty')
    
    if [ ! -z "$cost" ] && [ "$cost" != "null" ]; then
        echo -e "$((i+1)). ${BOLD}${service}${NC} - ${GREEN}USD ${cost}${NC}"
    else
        echo -e "$((i+1)). ${BOLD}${service}${NC}"
    fi
done

# Prompt for service deletion
echo -e "\n${YELLOW}Would you like to learn about deleting any of these services? (y/n)${NC}"
read -r response

if [[ "$response" =~ ^[Yy]$ ]]; then
    while true; do
        echo -e "\nEnter the number of the service you'd like information about (or 'q' to quit):"
        read -r selection
        
        if [[ "$selection" == "q" ]]; then
            break
        fi
        
        if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -gt 0 ] && [ "$selection" -le "${#services[@]}" ]; then
            index=$((selection-1))
            service=${services[$index]}
            display_deletion_info "$service" "$current_region"
        else
            echo -e "${RED}Invalid selection. Please enter a number between 1 and ${#services[@]} (or 'q' to quit)${NC}"
        fi
    done
fi

echo -e "\n${BOLD}Cleanup Information Complete${NC}"
echo -e "${YELLOW}Remember to:${NC}"
echo "1. Verify resources in AWS Console before deletion"
echo "2. Check for service dependencies"
echo "3. Back up any important data"
echo "4. Monitor billing dashboard for changes"

echo -e "\n${GREEN}For detailed billing information, visit:${NC}"
echo "https://console.aws.amazon.com/billing/home?#/"