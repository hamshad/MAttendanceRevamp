What you’re describing (consistent ~60 m offset + jumps to a nearby road) is a **real-world accuracy limitation**, not just noise. As a mobile developer, you shouldn’t try to “force GPS to be correct”—you should **model uncertainty and reject bad fixes**.

Here’s how to handle it properly in production-grade tracking systems.

---

## 1) Treat location as a probabilistic signal, not truth

Every Android `Location` object already gives you:

* `accuracy` (meters)
* `speed`
* `bearing`

If you’re ignoring `accuracy`, that’s the root problem.

**Rule: never trust a point blindly.**

```kotlin
if (location.accuracy > 30f) {
    // discard or downgrade confidence
}
```

For office/static scenarios, I’d be even stricter:

* Accept only ≤ 20–25 meters if possible

---

## 2) Detect “static user” state explicitly

You need a state machine:

```text
MOVING ↔ STATIONARY
```

### Detect stationary using:

* Speed < 0.5 m/s
* No displacement > X meters over Y seconds

Example:

```kotlin
if (location.speed < 0.5 && distanceFromLast < 10m for 30–60 sec) {
    state = STATIONARY
}
```

---

## 3) Freeze position when stationary (critical)

Once user is stationary:

👉 **Stop updating UI/backend with raw GPS**
👉 Hold last “trusted” location

This alone eliminates your issue.

```kotlin
if (state == STATIONARY) {
    return lastStableLocation
}
```

---

## 4) Apply distance + accuracy gating

When a new point arrives:

```kotlin
val distance = newLoc.distanceTo(lastLoc)

if (distance > newLoc.accuracy * 1.5) {
    // suspicious jump → reject
}
```

Why this works:

* If accuracy = 40m, a 60m jump is *not reliable*

---

## 5) Use clustering / median filtering

Instead of single-point decisions, buffer recent points:

* Keep last 5–10 locations
* Compute:

  * Median latitude/longitude
  * Or centroid of tight cluster

Reject outliers.

---

## 6) Use FusedLocationProvider correctly

Always prefer:

```kotlin
PRIORITY_BALANCED_POWER_ACCURACY
```

Not `HIGH_ACCURACY` in background unless needed:

* High accuracy increases jitter indoors due to weak GPS

Also configure:

```kotlin
setMinUpdateDistanceMeters(10f)
setMinUpdateIntervalMillis(5000)
```

---

## 7) Add a “confidence score”

Production apps (Uber, Swiggy, etc.) don’t rely on raw GPS.

Build a score:

```text
confidence = f(accuracy, speed consistency, point variance)
```

Only send updates when:

```text
confidence > threshold
```

---

## 8) Handle your exact case (office drift ~60m)

What’s happening:

* GPS weak indoors → fallback to Wi-Fi/cell
* Wi-Fi positioning maps you to nearby road
* Accuracy probably ~40–80m

### Fix:

When:

* speed ≈ 0
* repeated jitter within radius

👉 Lock location to a **stable centroid**

---

## 9) Advanced (recommended): Kalman filter

This is the “correct” engineering solution.

It:

* Smooths noise
* Rejects sudden jumps
* Predicts position based on prior state

If you want a practical shortcut:

* Use a lightweight 2D Kalman filter for lat/lng
* Or a simple low-pass filter:

```kotlin
filteredLat = α * newLat + (1 - α) * oldLat
```

(α ≈ 0.2–0.3)

---

## 10) Backend-side sanity checks (don’t skip this)

Even if client filters fail:

* Reject impossible jumps:

  * 60m in 1 second while speed = 0 → invalid
* Snap to last known stable cluster

---

## Bottom line

Your fix is not “better GPS”—it’s **control logic**:

1. Reject low-accuracy points
2. Detect stationary state
3. Freeze or smooth position
4. Filter jumps using accuracy-aware thresholds

---

If you want, I can give you a **production-ready Kotlin implementation** (with Kalman + stationary detection + clustering) that you can drop directly into your app.
