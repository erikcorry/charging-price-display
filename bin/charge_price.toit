// Copyright (C) 2023 Erik Corry.
// Use of this source code is governed by a Zero-Clause BSD license that can
// be found in the LICENSE file.

import .get-display

import certificate-roots
import color-tft show *
import encoding.json
import http
import ntp
import net
import pixel-display.element show *
import pixel-display.gradient show *
import pixel-display show *
import pixel-display.slider show *
import pixel-display.style show *
import font show *
import font-x11-adobe.sans-10-bold

sans ::= Font [sans-10-bold.ASCII]

HOST      ::= "www.elprisenligenu.dk"
CURRENCY  ::= "DKK"
// Get with: tail -n1 /usr/share/zoneinfo/Europe/Copenhagen 
TIME-ZONE ::= "CET-1CEST,M3.5.0,M10.5.0/3"  // Time zone with daylight savings switching.
GEOGRAPHY ::= "DK1"  // DK1 is West of Storebælt, DK2 is East of Storebælt.
CERT-ROOT ::= certificate-roots.ISRG-ROOT-X1

AFGIFT ::= 101  // øre/kWh

// Transport fees in øre/kWh.
TRANSPORT-FEES ::= [
    15,  // midnight to 1am.
    15,  // 1am to 2am.
    15,  // 2am to 3am.
    15,  // 3am to 4am.
    15,  // 4am to 5am.
    15,  // 5am to 6am.
    46,  // 6am to 7am.
    46,  // 7am to 8am.
    46,  // 8am to 9am.
    46,  // 9am to 10am.
    46,  // 10am to 11am.
    46,  // 11am to noon.
    46,  // noon to 1pm.
    46,  // 1pm to 2pm.
    46,  // 2pm to 3pm.
    46,  // 3pm to 4pm.
    46,  // 4pm to 5pm.
    138, // 5pm to 6pm.
    138, // 6pm to 7pm.
    138, // 7pm to 8pm.
    128, // 8pm to 9pm.
    46,  // 9pm to 10pm.
    46,  // 10pm to 11pm.
    46,  // 11pm to midnight.
]

main:
  set-timezone TIME-ZONE
  display/PixelDisplay := get-display M5-STACK-24-BIT-LANDSCAPE-SETTINGS
  display.background = 0x808080
  ui := UserInterface display
  fetcher := PriceFetcher ui
  fetcher.run

class HourPrice:
  hour/Time
  price/num

  constructor .hour .price:

  operator == other:
    if other is not HourPrice: return false
    return hour == other.hour and price == other.price

// Object that updates the price of electricity from an API.
class PriceFetcher:
  constructor .ui:
    client = http.Client.tls network
        --root-certificates=[CERT-ROOT]

  ui/UserInterface
  network := net.open
  client/http.Client
  today-string/string? := null
  tomorrow-string/string? := null
  today-prices/List? := null
  tomorrow-prices/List? := null

  run -> none:
    now/Time? := null
    while true:
      new-now := get-now
      if new-now: now = new-now
      if not now: continue

      // The API lets you fetch one day, using the local time zone
      // to determine when the day starts and ends.
      new-today-string := date-format now.local
      tomorrow := now + (Duration --h=24)
      new-tomorrow-string := date-format tomorrow.local
      if new-today-string != today-string: today-prices = null
      if new-tomorrow-string != tomorrow-string: tomorrow-prices = null
      // Catch for all intermittent network errors.
      catch --trace:
        if not today-prices:
          today-prices = get-prices new-today-string
        if not tomorrow-prices:
          tomorrow-prices = get-prices new-tomorrow-string
      today-string = new-today-string
      tomorrow-string = new-tomorrow-string
      ui.update now today-prices tomorrow-prices
      ms := (random 100_000) + 100_000
      print "Sleep for $(ms / 1000) seconds"
      sleep --ms=ms

  get-prices date-string/string -> List?:
    path := "/api/v1/prices/$(date-string)_$(GEOGRAPHY).json"
    print "Fetching $path"
    response := client.get --host=HOST --path=path
    if response.status-code == 200:
      data := json.decode-stream response.body
      return interpret-json data
    else:
      print "Response status code: $response.status-code"
      clear-ntp-adjustment
      return null

  /**
  Takes the JSON data from the API and returns a list
    of HourPrice objects.
  */
  interpret-json data -> List?:
    if not data: return null
    result := []
    data.do: | period |
      start := Time.parse period["time_start"]
      end := Time.parse period["time_end"]
      price := period["$(CURRENCY)_per_kWh"]
      result.add
          HourPrice start price
    return result

  static date-format date/TimeInfo -> string:
    return "$date.year/$(%02d date.month)-$(%02d date.day)"

  ntp-counter/int := 0
  ntp-result := null
  ntp-retry-timeout := 1000

  get-now -> Time?:
    // Catch for all intermittent network errors.
    catch --trace:
      // One time in 100 we bother the server for a new NTP adjustment.  Small
      // devices might not have any other process fetching the NTP time.
      if not ntp-result or ntp-counter % 100 == 0:
        ntp-result = ntp.synchronize
        ntp-retry-timeout = 1000
        if ntp-result: print "Getting NTP adjustment $ntp-result.adjustment"
      ntp-counter++
      if ntp-result:
        return Time.now + ntp-result.adjustment
    ntp-retry-timeout *= 2
    ntp-retry-timeout = max ntp-retry-timeout 300_000  // Max 5 minutes.
    print "NTP sleep $(ntp-retry-timeout)ms"
    sleep --ms=ntp-retry-timeout
    return null

  clear-ntp-adjustment -> none:
    // Fetching the prices might have failed because our clock is wrong.  Let's
    // try to get a new NTP adjustment next time.
    ntp-result = null

class UserInterface:
  display/PixelDisplay

  sliders/List := []
  labels/List := []

  constructor .display:
    div := Div --x=0 --y=0 --w=display.width --h=display.height --classes=["bg-div"]
    display.add div

    13.repeat:
      slider := Slider --x=(10 + it * 20) --y=0
      sliders.add slider
      div.add slider
      label := Label --x=(19 + it * 20) --classes=["slider-label"]
      labels.add label
      div.add label

    4.repeat:
      div.add
          Div --id="price-line-$it" --classes=["price-line"]
      div.add
          Label --id="price-label-$it" --classes=["price-label"]

    // These non-orthogonal gradients are pretty slow.  You can make
    // it faster by setting the angle to 180, or by using a single
    // color like 0xe0e0ff.
    background := GradientBackground --angle=150 --specifiers=[
        GradientSpecifier --color=0xf0f0ff 0,
        GradientSpecifier --color=0xb0b0df 100,
    ]

    price-gradient := GradientBackground --angle=0 --specifiers=[
        GradientSpecifier --color=0x00ff00 0,
        GradientSpecifier --color=0xffff00 40,
        GradientSpecifier --color=0xff0000 100,
    ]

    style := Style
        --type-map={
            "slider": Style --y=0 --w=18 --h=200 {
                "background-hi": price-gradient,
                "max": 400,
            },
        }
        --class-map={
            "bg-div": Style --background=background,
            "price-line": Style --x=5 --w=310 --h=1 --background=0x404040,
            "price-label": Style --x=305 --color=0x404040 --font=sans {
                "alignment": ALIGN-RIGHT,
            },
            "slider-label": Style --y=215 --font=sans --color=0 {
                "alignment": ALIGN-CENTER,
            },
        }
        --id-map={
            "price-line-0": Style --y=50,
            "price-line-1": Style --y=100,
            "price-line-2": Style --y=150,
            "price-line-3": Style --y=200,
            "price-label-0": Style --y=215 { "label": "0kr"},
            "price-label-1": Style --y=165 { "label": "1kr"},
            "price-label-2": Style --y=115 { "label": "2kr"},
            "price-label-3": Style --y=65 { "label": "3kr"},
        }
    display.set-styles [style]

  update now/Time today-prices/List? tomorrow-prices/List? -> none:
    hour-now/TimeInfo := now.local.with --m=0 --s=0 --ns=0
    start-of-this-hour/Time := hour-now.time
    hour-number := hour-now.h
    i := 0
    if not today-prices: today-prices = []
    if not tomorrow-prices: tomorrow-prices = []
    (today-prices + tomorrow-prices).do: | hour-price/HourPrice |
      if hour-price.hour >= start-of-this-hour and i < sliders.size:
        label := (hour-number + i) % 24
        price := hour-price.price * 100.to-int
        price += TRANSPORT-FEES[label]
        price += AFGIFT
        sliders[i].value = price
        labels[i].label = "$(label == 0 ? 24 : label)"
        i++
    while i < sliders.size:
      sliders[i].value = 0
      labels[i].label = ""
      i++
    display.draw

  static price-format price/num -> string:
    int-part := price.to-int
    frac-part := ((price - int-part) * 100).round
    if frac-part == 100:
      int-part++
      frac-part = 0
    return "$(int-part).$(%02d frac-part)"
