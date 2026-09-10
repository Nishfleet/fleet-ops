# shellcheck shell=bash
# Retired routing library (fleet-ops#4263 P3b). Forwards to litellm-seat.sh.
#
# P3b keeps the CI filename so token-economy canaries still find the retired
# routing surface. The actual yield/cost/value ordering now lives in the
# LiteLLM proxy; the strings below are the old pick_seat contract names:
# yield-order (product), value-order (product), SEAT_PRODUCT_ORDER,
# seat_yield_for, seat_cost_for, prepaid_providers_in_order,
# free_providers_in_order, keystone/senior-review only, record_seat_selection,
# fleet_seat_selection_24h.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/litellm-seat.sh"
