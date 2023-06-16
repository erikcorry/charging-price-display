// Copyright (C) 2023 Erik Corry.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import .get_display

import certificate_roots
import encoding.json
import http
import ntp
import net
import pixel_display show *
import pixel_display.texture show TEXT_TEXTURE_ALIGN_LEFT TEXT_TEXTURE_ALIGN_CENTER
import pixel_display.true_color
import pixel_display.histogram show TrueColorHistogram
import font show *
import font_x11_adobe.sans_10

sans ::= Font [sans_10.ASCII]

MAX_PRICE ::= 0.61  // Maximum price to pay for power is 1.0 per kWh, but we pay 0.39 in taxes and transport.
// API for current price (without VAT):
HOST      ::= "www.elprisenligenu.dk"
CURRENCY  ::= "DKK"
// Get with: tail -n1 /usr/share/zoneinfo/Europe/Copenhagen 
TIME_ZONE ::= "CET-1CEST,M3.5.0,M10.5.0/3"  // Time zone with daylight savings switching.
GEOGRAPHY ::= "DK1"  // DK1 is West of Storebælt, DK2 is East of Storebælt.
CERT_ROOT ::= certificate_roots.ISRG_ROOT_X1

LABEL_BOTTOM ::= 20
TICK_TOP ::= 22
HIST_LEFT ::= 60
HIST_TOP ::= 35
HIST_HEIGHT ::= 100
HIST_BARS ::= 18
HIST_BAR_WIDTH ::= 10
HIST_WIDTH ::= HIST_BARS * HIST_BAR_WIDTH
HIST_BAR_PAD ::= 2 // Gaps in bars.
TICK_OFFSET ::= (HIST_BAR_WIDTH - HIST_BAR_PAD) / 2

main:
  set_timezone TIME_ZONE
  task:: fetch_prices

// Task that updates the price of electricity from an API.
fetch_prices:
  interface := net.open
  client := http.Client.tls interface
      --root_certificates=[CERT_ROOT]
  today/string? := null
  json_result/List? := null

  while true:
    // Big catch for all intermittent network errors.
    catch --trace:
      now := get_now
      // The API lets you fetch one day, using the local time zone
      // to determine when the day starts and ends.
      local := now.local
      new_today := "$local.year/$(%02d local.month)-$(%02d local.day)"
      // They don't normally update the hourly prices after the day
      // started, so if we already have the prices for today, we
      // don't need to fetch them again.
      if new_today != today or not json_result:
        path := "/api/v1/prices/$(new_today)_$(GEOGRAPHY).json"
        print "Fetching $path"
        response := client.get --host=HOST --path=path
        if response.status_code == 200:
          json_result = json.decode_stream response.body
        else:
          print "Response status code: $response.status_code"
          clear_ntp_adjustment
      if json_result:
        // The JSON is just an array of hourly prices.
        json_result.do: | period |
          start := Time.from_string period["time_start"]
          end := Time.from_string period["time_end"]
          if start <= now < end:
            price := period["$(CURRENCY)_per_kWh"]
            situation = situation.update_price price
            print "Electricity $(price_format price) $CURRENCY/kWh"
            // Successful fetch, so we can set the variable and not fetch again.
            today = new_today
    // Random sleep to avoid hammering the server if it is down, or just after
    // midnight when we need to fetch a new day. This also avoids hammering the
    // grid with a huge power spike at the top of each hour (when there are
    // millions using this program!).
    ms := (random 100_000) + 100_000
    print "Sleep for $(ms / 1000) seconds"
    sleep --ms=ms

// Task that updates the LEDs and power based on the current situation.
control power/gpio.Pin? led/Led:
  old_situation := null
  while true:
    sleep --ms=20
    if situation != old_situation:
      old_situation = situation
      state := situation.state
      price := situation.price
      if state == ON:
        if power: power.set POWER_ON
        led.set 0.0 0.5 1.0 // Turquoise: Manual on.
        print "Turquoise"
      else if state == OFF:
        if power: power.set POWER_OFF
        led.set 1.0 0.0 1.0 // Purple: Manual off.
        print "Purple"
      else if price:
        if price <= MAX_PRICE:
          if power: power.set POWER_ON
          led.set 0.0 0.5 0.0 // Green: Auto on.
          print "Green"
        else:
          if power: power.set POWER_OFF
          if price <= MAX_PRICE * 2:
            led.set 1.0 0.2 0.0 // Orange: Auto off - medium price.
            print "Orange"
          else:
            led.set 1.0 0.0 0.0 // Red: Auto off - expensive.
            print "Red"
      else:
        led.set 0.0 0.0 0.0 // Black: No price, no manual override.
        print "Black"

ntp_counter/int := 0
ntp_result := null

get_now -> Time:
  // One time in 100 we bother the server for a new NTP adjustment.  Small
  // devices might not have any other process fetching the NTP time.
  if not ntp_result or ntp_counter % 100 == 0:
    ntp_result = ntp.synchronize
    print "Getting NTP adjustment $ntp_result.adjustment"
  ntp_counter++
  return Time.now + ntp_result.adjustment

clear_ntp_adjustment -> none:
  // Fetching the prices might have failed because our clock is wrong.  Let's
  // try to get a new NTP adjustment next time.
  ntp_result = null

price_format price/num -> string:
  int_part := price.to_int
  frac_part := ((price - int_part) * 100).round
  if frac_part == 100:
    int_part++
    frac_part = 0
  return "$(int_part).$(%02d frac_part)"

class Situation:
  display/TrueColorPixelDisplay
  current_hour/int? := null

  green_histogram/TrueColorPixelDisplay
  orange_histogram/TrueColorPixelDisplay
  red_histogram/TrueColorHistogram

  tick_marks/List
  hours/List

  prices/List := []

  constructor .display:
    context := display.context --landscape --color=WHITE --font=sans --alignment=TEXT_TEXTURE_ALIGN_CENTER
    histo_transform = context.transform
    green_histogram  = TrueColorHistogram HIST_X HIST_Y HIST_WIDTH HIST_HEIGHT histo_transform 1.0 (get_rgb 10 240 10)
    orange_histogram = TrueColorHistogram HIST_X HIST_Y HIST_WIDTH HIST_HEIGHT histo_transform 1.0 (get_rgb 200 200 10)
    red_histogram   = TrueColorHistogram HIST_X HIST_Y HIST_WIDTH HIST_HEIGHT histo_transform 1.0 (get_rgb 240 10 10)
    hours = List HIST_BARS / 3:
      display.text context -100 -100 ""
    tick_marks = List HIST_BARS / 3:
      display.filled_rectangle context -100 -100 1 10

  update_prices new_current_hour/int new_prices/List -> none:
    if new_prices.size > HIST_BARS: new_prices = new_prices[..HIST_BARS]
    differ := false
    (min new_prices.size prices.size).repeat: if new_prices[it] != prices[it]: differ = true
    if new_prices.size != prices.size or differ or new_current_hour != current_hour:
      current_hour = new_current_hour
      label_index := 0
      min_price := 1000000.0
      max_price := -1000000.0
      green_histogram.clear
      orange_histogram.clear
      red_histogram.clear
      HIST_BARS.repeat: | i |
        if (i + current_hour) % 3 == 0:
          h := (i + current_hour) % 24
          hours[label_index].text = h.stringify
          x := HIST_X + TICK_OFFSET + i * HIST_BAR_WIDTH
          hours[label_index].move_to x LABEL_BOTTOM
          tick_marks.move_to         x TICK_TOP
          label_index++
        if i < new_prices.size:
          price := new_prices[i]
          min_price = min min_price price
          max_price = max max_price price
        range := max_price - min_price
        hist_min := min_prices - 20
        hist_max := max_prices

      new_prices.do: | price |
        selected_hist/TrueColorHistogram := ?
        if price <= min_price + range / 3:
          selected_hist = green_histogram
        else if price <= min_price + 2 * range / 3:
          selected_hist = orange_histogram
        else:
          selected_hist = red_histogram
        zero_to_one = (price - hist_min) / (hist_max - hist_min).to_float
        pixel_height = zero_to_one * HIST_HEIGHT
        (HIST_BAR_WIDTH - HIST_BAR_PAD.repeat: selected_hist.add pixel_height
        HIST_BAR_PAD.repeat: selected_hist.add 0.0
        HIST_BAR_WIDTH.repeat:
          if selected_hist != red_histogram: red_histogram.add 0.0
          if selected_hist != orange_histogram: orange_histogram.add 0.0
          if selected_hist != green_histogram: green_histogram.add 0.0
      display.draw
