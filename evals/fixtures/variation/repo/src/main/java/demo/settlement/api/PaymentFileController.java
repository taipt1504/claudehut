package demo.settlement.api;

import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

@RestController
public class PaymentFileController {
  /** P8: the contract takes the variant (bank) — every bank needs its own layout. */
  @GetMapping("/payment-files")
  public byte[] export(@RequestParam String bank, @RequestParam String day) {
    return new byte[0];
  }

  /** N7: an id and a page size are parameters, not variants. */
  @GetMapping("/payments/{id}")
  public String one(@PathVariable String id, @RequestParam int size) {
    return id;
  }
}
