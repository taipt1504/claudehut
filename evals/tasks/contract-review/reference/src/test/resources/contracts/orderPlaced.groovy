// Spring Cloud Contract — provider contract for the OrderPlaced event.
// Verifies the v2 schema stays BACKWARD compatible: a v1 message (no discountCode) is still consumable,
// and discountCode is optional with a null default.
org.springframework.cloud.contract.spec.Contract.make {
    label 'orderPlaced_v2_backward_compatible'
    input {
        triggeredBy('orderPlacedWithoutDiscount()')
    }
    outputMessage {
        sentTo 'orders.placed'
        body([
            orderId     : 'o-1',
            totalMinor  : 4200,
            itemCount   : 3,
            discountCode: null
        ])
    }
}
