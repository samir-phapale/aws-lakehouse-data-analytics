# Rule forms accepted by the DataBrew API:
#   "AGG(<STAT>) <op> :val1"        aggregate; column_selectors for column stats
#   ":col1 <condition> :val1"       per value; threshold = % of rows that must pass
#   "is_between :val1 and :val2"    per value over column_selectors

locals {
  all_rows = 100

  rows_present = { name = "rows present", check = "AGG(ROWS_COUNT) > :val1", values = { ":val1" = "0" } }

  complete = { for column in [
    "customer_id", "seller_id", "product_id", "order_id", "purchased_at", "category_en",
    "zip_code_prefix", "event_id", "event_time", "c_custkey", "review_id",
    ] : column => {
    name    = "${column} complete"
    check   = "AGG(MISSING_VALUES_PERCENTAGE) == :val1"
    values  = { ":val1" = "0" }
    columns = [column]
  } }

  unique = { for column in ["customer_id", "seller_id", "product_id", "order_id", "zip_code_prefix", "event_id", "c_custkey"] :
    column => {
      name    = "${column} unique"
      check   = "AGG(UNIQUE_VALUES_PERCENTAGE) == :val1"
      values  = { ":val1" = "100" }
      columns = [column]
    }
  }

  no_duplicates = { name = "no duplicate rows", check = "AGG(DUPLICATE_ROWS_COUNT) == :val1", values = { ":val1" = "0" } }

  matches = {
    state      = "^[A-Z]{2}$"
    zip        = "^[0-9]{5}$"
    status     = "^(created|approved|invoiced|processing|shipped|delivered|canceled|unavailable)$"
    payment    = "^(credit_card|boleto|voucher|debit_card|unknown)$"
    event_type = "^ORDER_(PURCHASED|APPROVED|SHIPPED|DELIVERED|CANCELED|UNAVAILABLE)$"
    mktsegment = "^(AUTOMOBILE|BUILDING|FURNITURE|HOUSEHOLD|MACHINERY)$"
  }

  rulesets = {
    customers = [
      local.rows_present, local.complete["customer_id"], local.unique["customer_id"],
      { name = "state is a UF code", check = ":col1 matches :val1", values = { ":col1" = "`state`", ":val1" = local.matches.state }, threshold = local.all_rows },
      { name = "zip has 5 digits", check = ":col1 matches :val1", values = { ":col1" = "`zip_code_prefix`", ":val1" = local.matches.zip }, threshold = local.all_rows },
    ]
    sellers = [
      local.rows_present, local.complete["seller_id"], local.unique["seller_id"],
      { name = "state is a UF code", check = ":col1 matches :val1", values = { ":col1" = "`state`", ":val1" = local.matches.state }, threshold = local.all_rows },
    ]
    products = [
      local.rows_present, local.complete["product_id"], local.unique["product_id"], local.complete["category_en"],
      { name = "weight not negative", check = ":col1 >= :val1", values = { ":col1" = "`weight_g`", ":val1" = "0" }, threshold = 99 },
    ]
    geolocation = [
      local.rows_present, local.complete["zip_code_prefix"], local.unique["zip_code_prefix"],
      { name = "lat inside Brazil", check = "is_between :val1 and :val2", values = { ":val1" = "-34", ":val2" = "6" }, columns = ["lat"], threshold = local.all_rows },
      { name = "lng inside Brazil", check = "is_between :val1 and :val2", values = { ":val1" = "-74", ":val2" = "-34" }, columns = ["lng"], threshold = local.all_rows },
    ]
    orders = [
      local.rows_present, local.complete["order_id"], local.unique["order_id"], local.complete["purchased_at"],
      { name = "status known", check = ":col1 matches :val1", values = { ":col1" = "`order_status`", ":val1" = local.matches.status }, threshold = local.all_rows },
    ]
    order_items = [
      local.rows_present, local.complete["order_id"], local.no_duplicates,
      { name = "price not negative", check = ":col1 >= :val1", values = { ":col1" = "`price`", ":val1" = "0" }, threshold = local.all_rows },
      { name = "freight not negative", check = ":col1 >= :val1", values = { ":col1" = "`freight_value`", ":val1" = "0" }, threshold = local.all_rows },
    ]
    order_payments = [
      local.rows_present, local.complete["order_id"], local.no_duplicates,
      { name = "payment not negative", check = ":col1 >= :val1", values = { ":col1" = "`payment_value`", ":val1" = "0" }, threshold = local.all_rows },
      { name = "payment type known", check = ":col1 matches :val1", values = { ":col1" = "`payment_type`", ":val1" = local.matches.payment }, threshold = local.all_rows },
    ]
    order_reviews = [
      local.rows_present, local.complete["review_id"], local.complete["order_id"],
      { name = "score 1 to 5", check = ":col1 is_between :val1 and :val2", values = { ":col1" = "`review_score`", ":val1" = "1", ":val2" = "5" }, threshold = local.all_rows },
    ]
    order_events = [
      local.rows_present, local.complete["event_id"], local.unique["event_id"], local.complete["event_time"],
      { name = "event type known", check = ":col1 matches :val1", values = { ":col1" = "`event_type`", ":val1" = local.matches.event_type }, threshold = local.all_rows },
    ]
    tpch_customer = [
      local.rows_present, local.complete["c_custkey"], local.unique["c_custkey"],
      { name = "segment known", check = ":col1 matches :val1", values = { ":col1" = "`c_mktsegment`", ":val1" = local.matches.mktsegment }, threshold = local.all_rows },
      { name = "nation key 0 to 24", check = ":col1 is_between :val1 and :val2", values = { ":col1" = "`c_nationkey`", ":val1" = "0", ":val2" = "24" }, threshold = local.all_rows },
    ]
  }
}
