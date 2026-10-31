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
