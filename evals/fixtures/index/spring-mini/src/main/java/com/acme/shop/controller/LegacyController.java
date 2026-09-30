package com.acme.shop.controller;

import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;

@Controller
public class LegacyController {
  static final String PATH = "/legacy/home";

  @GetMapping(value = PATH)
  public String home() {
    return "home";
  }
}
