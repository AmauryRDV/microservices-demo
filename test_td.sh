#!/usr/bin/env bash
set -uo pipefail  # Remove 'e' to allow non-zero exits in checks

#═══════════════════════════════════════════════════════════════════════════════
# TD2 : Test Suite Complète - Cloud Tasks, Firestore & GCP
# Tests toutes les fonctionnalités Phase 3 & 4
#═══════════════════════════════════════════════════════════════════════════════

PROJECT_ID="gcp-ynov"
REGION="europe-west1"
INSTANCE_1_SERVICE="td-cloud-instance-1"
INSTANCE_2_SERVICE="td-cloud-instance-2"
URL_1="https://td-cloud-instance-1-442272891992.europe-west1.run.app"
URL_2="https://td-cloud-instance-2-442272891992.europe-west1.run.app"
SNAPSHOT_BUCKET="td-cloud-snapshots-gcp-ynov"
ADMIN_KEY="td-secret-2026"

# Couleurs pour output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Compteurs
TESTS_PASSED=0
TESTS_FAILED=0

#═══════════════════════════════════════════════════════════════════════════════
# Fonctions utilitaires
#═══════════════════════════════════════════════════════════════════════════════

print_header() {
    echo -e "\n${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}\n"
}

print_test() {
    echo -e "${YELLOW}→ $1${NC}"
}

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    ((TESTS_FAILED++))
}

#═══════════════════════════════════════════════════════════════════════════════
# Vérification des prérequis
#═══════════════════════════════════════════════════════════════════════════════

print_header "VÉRIFICATION DES PRÉREQUIS"

if [[ -z "$URL_1" || -z "$URL_2" ]]; then
    echo -e "${RED}Erreur: URL_1 et URL_2 introuvables.${NC}"
    echo "Assurez-vous que td-cloud-instance-1 et td-cloud-instance-2 sont déployés."
    exit 1
fi

echo -e "URL_1: ${BLUE}$URL_1${NC}"
echo -e "URL_2: ${BLUE}$URL_2${NC}"
echo -e "Bucket: ${BLUE}gs://${SNAPSHOT_BUCKET}${NC}\n"

# Vérifier la connectivité
print_test "Vérification de Instance 1"
if timeout 25 curl -s --connect-timeout 20 "$URL_1/health" > /dev/null 2>&1; then
    pass "Instance 1 accessible"
else
    fail "Instance 1 inaccessible"
    exit 1
fi

print_test "Vérification de Instance 2"
if timeout 25 curl -s --connect-timeout 20 "$URL_2/health" > /dev/null 2>&1; then
    pass "Instance 2 accessible"
else
    echo -e "${YELLOW}⚠ Instance 2 inaccessible, certains tests seront ignorés${NC}"
fi

#═══════════════════════════════════════════════════════════════════════════════
# TEST 1 : RATE LIMITING
#═══════════════════════════════════════════════════════════════════════════════

print_header "TEST 1 : RATE LIMITING (5 requêtes/minute par player)"

print_test "Envoi de 7 requêtes consécutives avec le même X-Player-ID"

PLAYER="rate-limit-test-$(date +%s)"
PUBLISHED_COUNT=0
BLOCKED_COUNT=0

for i in {1..7}; do
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$URL_1/publish" \
        -H "Content-Type: application/json" \
        -H "X-Player-ID: $PLAYER" \
        -d '{"message": "rate limit test event"}')
    
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | head -n-1)
    
    if [[ "$HTTP_CODE" == "200" ]]; then
        ((PUBLISHED_COUNT++))
        echo "  Requête $i: HTTP $HTTP_CODE ✓"
    elif [[ "$HTTP_CODE" == "429" ]]; then
        ((BLOCKED_COUNT++))
        echo "  Requête $i: HTTP $HTTP_CODE (Rate limited) ✓"
    else
        echo "  Requête $i: HTTP $HTTP_CODE (Inattendu)"
    fi
    
    sleep 0.2
done

echo ""

if [[ $PUBLISHED_COUNT -ge 5 ]]; then
    pass "Les 5 premières requêtes ont été acceptées (count: $PUBLISHED_COUNT)"
else
    fail "Moins de 5 requêtes acceptées (count: $PUBLISHED_COUNT)"
fi

if [[ $BLOCKED_COUNT -ge 2 ]]; then
    pass "Les requêtes au-delà de 5 ont été bloquées (count: $BLOCKED_COUNT)"
else
    fail "Pas assez de requêtes bloquées (count: $BLOCKED_COUNT)"
fi

#═══════════════════════════════════════════════════════════════════════════════
# TEST 2 : ANALYTICS
#═══════════════════════════════════════════════════════════════════════════════

print_header "TEST 2 : ANALYTICS - Vérification des compteurs Firestore"

print_test "Récupération des données analytics avec X-Admin-Key"

ANALYTICS=$(curl -s "$URL_1/analytics" \
    -H "X-Admin-Key: $ADMIN_KEY")

# Vérifier que la réponse contient les clés attendues
if echo "$ANALYTICS" | grep -q '"analytics"'; then
    pass "Endpoint /analytics retourne un JSON valide"
else
    fail "Endpoint /analytics ne retourne pas un JSON valide"
fi

if echo "$ANALYTICS" | grep -q '"quotas"'; then
    pass "Réponse contient la clé 'quotas'"
else
    fail "Réponse ne contient pas la clé 'quotas'"
fi

# Compter le nombre de joueurs tracés
PLAYER_COUNT=$(echo "$ANALYTICS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('analytics', {})))" 2>/dev/null || echo "0")

if [[ $PLAYER_COUNT -gt 0 ]]; then
    pass "Au moins $PLAYER_COUNT joueur(s) tracé(s) dans analytics"
else
    fail "Aucun joueur tracé dans analytics"
fi

# Afficher un aperçu des analytics
echo -e "\n${YELLOW}Aperçu des données analytics:${NC}"
echo "$ANALYTICS" | python3 -m json.tool 2>/dev/null | head -30

#═══════════════════════════════════════════════════════════════════════════════
# TEST 3 : ISOLATION DES QUOTAS PAR PLAYER_ID
#═══════════════════════════════════════════════════════════════════════════════

print_header "TEST 3 : ISOLATION DES QUOTAS - Deux joueurs = deux quotas indépendants"

PLAYER_A="player-iso-A-$(date +%s)"
PLAYER_B="player-iso-B-$(date +%s)"

print_test "Remplissage du quota de $PLAYER_A (5 requêtes)"

for i in {1..5}; do
    curl -s -X POST "$URL_1/publish" \
        -H "Content-Type: application/json" \
        -H "X-Player-ID: $PLAYER_A" \
        -d '{"message": "quota fill event"}' > /dev/null
    echo "  Requête $i pour $PLAYER_A envoyée"
    sleep 0.1
done

print_test "Vérification que $PLAYER_A est maintenant bloqué"

RESPONSE_A=$(curl -s -w "\n%{http_code}" -X POST "$URL_1/publish" \
    -H "Content-Type: application/json" \
    -H "X-Player-ID: $PLAYER_A" \
    -d '{"message": "should be blocked"}')

HTTP_CODE_A=$(echo "$RESPONSE_A" | tail -1)

if [[ "$HTTP_CODE_A" == "429" ]]; then
    pass "$PLAYER_A est bloqué (HTTP 429)"
else
    fail "$PLAYER_A ne devrait pas passer (reçu HTTP $HTTP_CODE_A)"
fi

print_test "Vérification que $PLAYER_B n'est PAS affecté par le quota de $PLAYER_A"

RESPONSE_B=$(curl -s -w "\n%{http_code}" -X POST "$URL_1/publish" \
    -H "Content-Type: application/json" \
    -H "X-Player-ID: $PLAYER_B" \
    -d '{"message": "player B should work"}')

HTTP_CODE_B=$(echo "$RESPONSE_B" | tail -1)

if [[ "$HTTP_CODE_B" == "200" ]]; then
    pass "$PLAYER_B a pu publier malgré le quota plein de $PLAYER_A"
else
    fail "$PLAYER_B devrait pouvoir publier (reçu HTTP $HTTP_CODE_B)"
fi

#═══════════════════════════════════════════════════════════════════════════════
# CHECKPOINT 1 : HEALTH CHECKS
#═══════════════════════════════════════════════════════════════════════════════

print_header "CHECKPOINT 1 : HEALTH CHECKS - Vérifier que les deux instances répondent"

print_test "Health check sur Instance 1"
HEALTH_1=$(curl -s "$URL_1/health")

if echo "$HEALTH_1" | grep -q '"status".*"healthy"'; then
    pass "Instance 1 est healthy"
    echo "  Réponse: $HEALTH_1"
else
    fail "Instance 1 n'est pas healthy"
    echo "  Réponse: $HEALTH_1"
fi

print_test "Health check sur Instance 2"
HEALTH_2=$(timeout 25 curl -s --connect-timeout 20 "$URL_2/health" 2>/dev/null || echo "{}")

if echo "$HEALTH_2" | grep -q '"status".*"healthy"'; then
    pass "Instance 2 est healthy"
    echo "  Réponse: $HEALTH_2"
else
    echo -e "${YELLOW}⚠ Instance 2 ne répond pas${NC}"
fi

#═══════════════════════════════════════════════════════════════════════════════
# CHECKPOINT 2 : SNAPSHOTS CLOUD STORAGE
#═══════════════════════════════════════════════════════════════════════════════

print_header "CHECKPOINT 2 : SNAPSHOTS - Vérifier que les snapshots sont créés en Cloud Storage"

print_test "Liste des snapshots dans gs://${SNAPSHOT_BUCKET}/snapshots/"

SNAPSHOT_LIST=$(gsutil ls "gs://${SNAPSHOT_BUCKET}/snapshots/" 2>/dev/null || true)

if [[ -n "$SNAPSHOT_LIST" ]]; then
    SNAPSHOT_COUNT=$(echo "$SNAPSHOT_LIST" | wc -l)
    pass "Snapshots trouvés dans Cloud Storage (environ $SNAPSHOT_COUNT fichiers)"
    echo -e "\n${YELLOW}Derniers snapshots:${NC}"
    gsutil ls -l "gs://${SNAPSHOT_BUCKET}/snapshots/**" 2>/dev/null | tail -5
else
    echo -e "${YELLOW}⚠ Aucun snapshot trouvé (normal si aucune tâche Cloud Tasks n'a été exécutée)${NC}"
fi

#═══════════════════════════════════════════════════════════════════════════════
# CHECKPOINT 3 : FIRESTORE DOCUMENTS
#═══════════════════════════════════════════════════════════════════════════════

print_header "CHECKPOINT 3 : FIRESTORE - Vérifier les collections rate_limits et analytics"

ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)

if [[ -z "$ACCESS_TOKEN" ]]; then
    echo -e "${YELLOW}⚠ Impossible d'obtenir le token d'accès pour Firestore${NC}"
else
    print_test "Récupération des documents rate_limits"
    
    RATE_LIMITS=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents/rate_limits" 2>/dev/null || echo "{}")
    
    RATE_LIMIT_COUNT=$(echo "$RATE_LIMITS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('documents', [])))" 2>/dev/null || echo "0")
    
    if [[ $RATE_LIMIT_COUNT -gt 0 ]]; then
        pass "Collection rate_limits contient $RATE_LIMIT_COUNT document(s)"
    else
        echo -e "${YELLOW}⚠ Aucun document dans rate_limits${NC}"
    fi
    
    print_test "Récupération des documents analytics"
    
    ANALYTICS_DOCS=$(curl -s -H "Authorization: Bearer ${ACCESS_TOKEN}" \
        "https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents/analytics" 2>/dev/null || echo "{}")
    
    ANALYTICS_COUNT=$(echo "$ANALYTICS_DOCS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('documents', [])))" 2>/dev/null || echo "0")
    
    if [[ $ANALYTICS_COUNT -gt 0 ]]; then
        pass "Collection analytics contient $ANALYTICS_COUNT document(s)"
    else
        echo -e "${YELLOW}⚠ Aucun document dans analytics${NC}"
    fi
fi

#═══════════════════════════════════════════════════════════════════════════════
# TEST BONUS : AUTHENTIFICATION DE L'ENDPOINT /analytics
#═══════════════════════════════════════════════════════════════════════════════

print_header "TEST BONUS : SÉCURITÉ - Vérifier l'authentification de /analytics"

print_test "Tentative d'accès à /analytics SANS X-Admin-Key"

RESPONSE_NO_KEY=$(curl -s -w "\n%{http_code}" "$URL_1/analytics")
HTTP_CODE_NO_KEY=$(echo "$RESPONSE_NO_KEY" | tail -1)

if [[ "$HTTP_CODE_NO_KEY" == "401" ]]; then
    pass "Accès refusé sans X-Admin-Key (HTTP 401)"
else
    echo -e "${YELLOW}⚠ Code inattendu: HTTP $HTTP_CODE_NO_KEY${NC}"
fi

print_test "Tentative d'accès avec mauvaise clé"

RESPONSE_WRONG_KEY=$(curl -s -w "\n%{http_code}" "$URL_1/analytics" \
    -H "X-Admin-Key: wrong-key-123")
HTTP_CODE_WRONG_KEY=$(echo "$RESPONSE_WRONG_KEY" | tail -1)

if [[ "$HTTP_CODE_WRONG_KEY" == "401" ]]; then
    pass "Accès refusé avec mauvaise clé (HTTP 401)"
else
    echo -e "${YELLOW}⚠ Code inattendu: HTTP $HTTP_CODE_WRONG_KEY${NC}"
fi

#═══════════════════════════════════════════════════════════════════════════════
# RÉSUMÉ FINAL
#═══════════════════════════════════════════════════════════════════════════════

print_header "RÉSUMÉ DES TESTS"

TOTAL=$((TESTS_PASSED + TESTS_FAILED))

echo -e "${GREEN}Réussis: $TESTS_PASSED${NC}"
echo -e "${RED}Échoués: $TESTS_FAILED${NC}"
echo -e "Total:   $TOTAL"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "\n${GREEN}✓ TOUS LES TESTS SONT PASSÉS${NC}\n"
    exit 0
else
    echo -e "\n${RED}✗ CERTAINS TESTS ONT ÉCHOUÉ${NC}\n"
    exit 1
fi
