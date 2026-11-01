package pl.mwgo.macdroidsync

import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Calendar
import java.util.TimeZone
import java.util.UUID
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * What a Fujifilm camera takes over Bluetooth LE for its location and clock,
 * byte for byte as FUJIFILM XApp writes it. All numbers are little endian.
 */
object FujifilmGeo {

    val LOCATION_AND_SPEED: UUID = UUID.fromString("0F36EC14-29E5-411A-A1B6-64EE8383F090")
    val UTC_AND_TIMEZONE: UUID = UUID.fromString("C52EDBCE-1FE2-4ECC-9483-907E6592BE9E")
    val DATE_TIME: UUID = UUID.fromString("B9BFD37F-CCAD-4D36-A1EE-018E792B3EDF")
    /** Notified by the camera when it wants a location, once per sync cycle. */
    val LOCATION_SYNC_STATE: UUID = UUID.fromString("AD06C7B7-F41A-46F4-A29A-712055319122")
    /** Notified by the camera when it wants the time. */
    val DATE_SYNC_STATE: UUID = UUID.fromString("F9150137-5D40-4801-A8DC-F7FC5B01DA50")
    val LOCATION_SYNC_SETTING: UUID = UUID.fromString("AAB609C4-94DD-4D89-BC60-665D5090B828")
    val LOCATION_SYNC_CYCLE: UUID = UUID.fromString("C95D91AE-B247-4D6D-8661-7DD5D6A0F85B")
    /**
     * XApp introduces itself on every connection, and the camera takes control
     * requests only after that: this number read and written back with the
     * XApp bit set, the phone's name, and the application information.
     */
    val IDENTIFICATION_NUMBER: UUID = UUID.fromString("F557D96B-8284-4667-8793-B971C1DECA2A")
    val DEVICE_NAME: UUID = UUID.fromString("85B9163E-62D1-49FF-A6F5-054B4630D4A1")
    val APPLICATION_INFORMATION: UUID = UUID.fromString("8B5ECF55-FC6B-40D0-B4C1-76F64E5453C7")
    const val XAPP_IDENTIFIER = 0x20000000
    /** XApp, protocol version 0x0101. */
    val XAPP_INFORMATION = byteArrayOf(0x80.toByte(), 1, 1)
    val POWER_KEY_STATE: UUID = UUID.fromString("F90F7D3A-3B64-45C6-AB21-933900184837")

    /** Starts the camera's Wi-Fi for a phone to view and import its pictures: 3, in-camera viewing. */
    val FUNCTION_LAUNCH_REQUEST: UUID = UUID.fromString("600655E6-3637-42F1-8FB2-44EFC5C63B13")
    const val FUNCTION_IN_CAMERA_VIEWING = 3
    /** Notified as the access point comes up: 0x8001 launched, 0x8002 launching, 0x8000 failed. */
    val AP_STATE: UUID = UUID.fromString("A68E3F66-0FCC-4395-8D4C-AA980B5877FA")
    const val AP_LAUNCHED = 0x8001
    const val AP_FAILED = 0x8000
    val WIFI_SSID: UUID = UUID.fromString("BF6DC9CF-3606-4EC9-A4C8-D77576E93EA4")
    val WIFI_PASSPHRASE: UUID = UUID.fromString("E809256A-915C-4967-92E8-53B7D4CAD213")
    /** The camera's Wi-Fi MAC as "AA-BB-…", which is the access point's BSSID. */
    val WIFI_MAC: UUID = UUID.fromString("49A12959-DFAA-4EB2-89CE-62548AD948F3")

    fun text(value: ByteArray): String = String(value, Charsets.US_ASCII).substringBefore('\u0000').trim()

    fun uint16(value: ByteArray): Int =
        if (value.size >= 2) (value[0].toInt() and 0xFF) or ((value[1].toInt() and 0xFF) shl 8) else -1

    /** In the Camera Control service: the shutter button, as a uint16 state. */
    val SHOOTING_REQUEST: UUID = UUID.fromString("7FCF49C6-4FF0-4777-A03D-1A79166AF7A8")
    const val SHUTTER_UP = 0
    const val SHUTTER_HALF = 1
    const val SHUTTER_FULL = 2
    val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")

    /** The intervals XApp offers, in seconds; the camera is told the chosen one. */
    val INTERVALS = listOf(10, 15, 20, 30, 60, 120, 240, 480)
    const val DEFAULT_INTERVAL = 120

    /** Worse than this a fix would put the photos in the wrong street, so it is not sent. */
    const val MAX_ACCURACY_M = 100f

    /**
     * 23 bytes: latitude and longitude in 1e-7 degrees, altitude in metres,
     * speed in cm/s, then the UTC time of the fix.
     */
    fun location(latitude: Double, longitude: Double, altitude: Double, speed: Float, fixTime: Long): ByteArray {
        val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { timeInMillis = fixTime }
        return ByteBuffer.allocate(23).order(ByteOrder.LITTLE_ENDIAN)
            .putInt((latitude * 1e7).roundToInt())
            .putInt((longitude * 1e7).roundToInt())
            .putInt(altitude.roundToInt())
            .putInt((speed * 100).roundToInt())
            .putDate(utc)
            .array()
    }

    /**
     * 12 bytes: the UTC time, the zone's standard offset as hours times 100
     * (+05:30 is 550), and whether summer time is in effect.
     */
    fun utcAndTimezone(now: Long, zone: TimeZone): ByteArray {
        val utc = Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply { timeInMillis = now }
        return ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN)
            .putDate(utc)
            .putInt(offset(zone.rawOffset / 1000))
            .put(if (zone.inDaylightTime(java.util.Date(now))) 1 else 0)
            .array()
    }

    /** 7 bytes of local time, for cameras without the UTC characteristic. */
    fun dateTime(now: Long, zone: TimeZone): ByteArray {
        val local = Calendar.getInstance(zone).apply { timeInMillis = now }
        return ByteBuffer.allocate(7).order(ByteOrder.LITTLE_ENDIAN).putDate(local).array()
    }

    fun shutter(state: Int): ByteArray = interval(state)

    /** The number read from the camera, with the XApp bit set, as XApp writes it back. */
    fun identification(read: ByteArray): ByteArray? {
        if (read.size != 4) return null
        val number = ByteBuffer.wrap(read).order(ByteOrder.LITTLE_ENDIAN).int or XAPP_IDENTIFIER
        return ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(number).array()
    }

    fun deviceName(name: String): ByteArray = name.toByteArray(Charsets.UTF_8) + 0

    fun interval(seconds: Int): ByteArray =
        ByteBuffer.allocate(2).order(ByteOrder.LITTLE_ENDIAN).putShort(seconds.toShort()).array()

    /** Hours times 100, with quarter hours as 25, 50 and 75. */
    internal fun offset(seconds: Int): Int {
        val hours = seconds / 3600
        val minutes = abs(seconds % 3600) / 60
        val sign = if (seconds < 0) -1 else 1
        return hours * 100 + sign * (minutes * 100 / 60)
    }

    private fun ByteBuffer.putDate(calendar: Calendar): ByteBuffer =
        putShort(calendar.get(Calendar.YEAR).toShort())
            .put((calendar.get(Calendar.MONTH) + 1).toByte())
            .put(calendar.get(Calendar.DAY_OF_MONTH).toByte())
            .put(calendar.get(Calendar.HOUR_OF_DAY).toByte())
            .put(calendar.get(Calendar.MINUTE).toByte())
            .put(calendar.get(Calendar.SECOND).toByte())
}
