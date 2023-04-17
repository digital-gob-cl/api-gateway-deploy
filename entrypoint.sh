#!/bin/bash
set -e

ls -la

if [ ! -z "$INPUT_ENVIRONMENT" ];
then 
    ENVIRONMENT=$INPUT_ENVIRONMENT
fi

PROJECT=$INPUT_PROJECT

echo "Revisando balancers"
NLB_LIST=$(aws elbv2 describe-load-balancers | jq -r ' [  .LoadBalancers[] | select( .Type=="network" ) |   { arn: .LoadBalancerArn, hostname: .DNSName } ] ')

EKS_SERVICE_HOSTNAME=$(./kubectl get services -l cpat.service=$SERVICE_NAME -n cpat -o json | jq -r ' .items[].status.loadBalancer.ingress[].hostname')

echo "Buscando NLB: $EKS_SERVICE_HOSTNAME"

if [ -z "$EKS_SERVICE_HOSTNAME" ];
then
    echo "No se ha encotrado el servicio etiquetado como $EKS_SERVICE_HOSTNAME"
    echo "Revisar que la etiqueta (label) 'cpat.service' tenga el nombre dek servucui $EKS_SERVICE_HOSTNAME"
    exit 1
fi
#Al menos un NLB debe salir desde acá, sino lo hay, se supone que no se ha levantado
ARN=$(echo $NLB_LIST | jq --arg h $EKS_SERVICE_HOSTNAME -r '.[] | select( .hostname == $h ) | .arn' )

if [ -z "$ARN" ];
then
    echo "El servicio $SERVICE_NAME, no tiene asociado un NLB"
    exit 1
fi
#Listar los links que estan desplegados
NLBS=$(aws apigateway get-vpc-links | jq -r ' [ .items[].targetArns[] ] ')

#Seleccionar el NLB asociado al servicio
RES=$(echo $NLBS | jq --arg t $ARN 'select( . | index($t) )')
echo "Resultado de la busqueda: $RES"
echo "Verificar si existe VPC Link"
if [ -z "$RES" ];
then
    echo "No existe el VPC Link, procediendo a crearlo"
    echo "$PROJECT-$SERVICE_NAME-$ENVIRONMENT-link"

    aws apigateway create-vpc-link \
        --name "$PROJECT-$SERVICE_NAME-$ENVIRONMENT-link" \
        --description "Link para API servicio $SERVICE_NAME en ambiente $ENVIRONMENT" \
        --target-arns "$ARN" \
        --tags "Environment=$ENVIRONMENT,Project=$PROJECT,Purpose=API"
else
    echo "Ya existe NLB para el servicio $SERVICE_NAME"
fi
#Actualizando API

API_NAME="$PROJECT-$ENVIRONMENT-$SERVICE_NAME-api"

#Check si existe api gateway 
API_DATA=$(aws apigateway get-rest-apis | jq -r --arg n $API_NAME ' .items[] | select( .name == $n)')

ID=$(echo "$API_DATA" | jq -r '.id')

if [ -z ${API_DATA} ];
then
    echo "Creando API Gateway"
    API_DATA=$(aws apigateway create-rest-api --name=$API_NAME \
                        --endpoint-configuration "types=REGIONAL" \
                        --description "API Gateway servicio $SERVICE_NAME")

    ID=$(echo "$API_DATA" | jq -r '.id')
    echo "APi gateway con Id: $ID, se ha creado" 
fi

if [[ "$OSTYPE" == "linux-gnu"* ]];
then
    echo "$OSTYPE"
    base64 ./${INPUT_SWAGGER_PATH} > ./swager_body.b64
else
    base64 -i ./${INPUT_SWAGGER_PATH} -o ./swager_body.b64
fi 
    
echo "Actualizando API $ID"

aws apigateway put-rest-api --rest-api-id $ID \
        --body file://./swager_body.b64 
