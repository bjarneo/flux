package org.omarchy.flux.core

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Telephony
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

private const val TAG = "FluxSms"

/** How long the watch waits after an SMS table change before it reads the tables, in milliseconds. */
private const val CHANGE_DELAY_MS = 1_000L

/** The most conversations that 1 answer lists. */
private const val MAX_CONVERSATIONS = 500

/** The most new messages that 1 change sends. */
private const val MAX_NEW = 200

/** The longest MMS text part that Flux reads from a file, in bytes. */
private const val MAX_PART_BYTES = 64 * 1024

/** How long a contact name stays in the cache, in milliseconds. */
private const val NAME_TTL_MS = 10 * 60_000L

// The address types of the MMS address table. They are PDU header values.
private const val MMS_FROM = 137
private const val MMS_TO = 151
private const val MMS_CC = 130
private const val MMS_BCC = 129

/** The MMS address that stands for this phone. */
private const val MMS_SELF = "insert-address-token"

/** The SMS rows that hold a message. Drafts are left out. */
private const val SMS_SHOWN = "${Telephony.Sms.TYPE} != 3"

/** The MMS rows that hold a message: sent requests and retrieved messages. Drafts are left out. */
private const val MMS_SHOWN = "${Telephony.Mms.MESSAGE_BOX} != 3 AND ${Telephony.Mms.MESSAGE_TYPE} IN (128, 132)"

/**
 * The text messages of this phone for the computers. While the Text
 * messages switch is on and the phone allows SMS access, it answers the SMS
 * requests of a computer, sends text messages for it, and sends each new
 * message to the computers. The work runs on 1 thread, in order.
 *
 * Flux sends a text message to 1 address. A message to a group needs MMS,
 * and Flux does not send MMS. It reads the text of MMS messages.
 */
object SmsSync {
    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { Thread(it, "flux-sms").apply { isDaemon = true } }
    private val scan = Runnable { work("change scan") { pushChanges(FluxCore) } }

    // The main thread uses the observer.
    private var observer: ContentObserver? = null

    // The worker uses the rest.
    private val changes = SmsChanges()
    private var marked = false
    private var lastSms = Mark(0, 0)
    private var lastMms = Mark(0, 0)
    private val nameCache = HashMap<String, Pair<String?, Long>>()

    /** The newest ID and date that the change scan has seen in 1 table, in the units of that table. */
    private data class Mark(val id: Long, val date: Long)

    /** The permissions to ask for. The contacts add the names, and the user can refuse them. */
    fun permissions(): Array<String> =
        arrayOf(Manifest.permission.READ_SMS, Manifest.permission.SEND_SMS, Manifest.permission.READ_CONTACTS)

    /** True when the phone lets Flux read and send text messages. */
    fun hasAccess(context: Context): Boolean =
        granted(context, Manifest.permission.READ_SMS) && granted(context, Manifest.permission.SEND_SMS)

    /** True when the phone can send text messages. A tablet without a SIM slot cannot. */
    fun supported(context: Context): Boolean {
        val feature = if (Build.VERSION.SDK_INT >= 33) PackageManager.FEATURE_TELEPHONY_MESSAGING else PackageManager.FEATURE_TELEPHONY
        return context.packageManager.hasSystemFeature(feature)
    }

    /** True when the phone offers its text messages to the computers. */
    fun enabled(context: Context): Boolean = FluxCore.settings.syncSms && supported(context) && hasAccess(context)

    /** Starts the change watch. The service calls it while text messages are on. */
    fun start(context: Context) {
        val app = context.applicationContext
        // The watch sends only the messages that arrive after this.
        work("start") { markNewest(app) }
        main.post {
            if (observer != null) return@post
            val o = object : ContentObserver(main) {
                override fun onChange(selfChange: Boolean) = poke()
            }
            // The SMS and MMS tables also report each change on the combined table, but not on all phones.
            runCatching {
                for (uri in listOf(Telephony.MmsSms.CONTENT_URI, Telephony.Sms.CONTENT_URI, Telephony.Mms.CONTENT_URI)) {
                    app.contentResolver.registerContentObserver(uri, true, o)
                }
            }
                .onSuccess { observer = o }
                .onFailure {
                    app.contentResolver.unregisterContentObserver(o)
                    Log.w(TAG, "watch failed", it)
                }
        }
    }

    /** Stops the change watch. */
    fun stop(context: Context) {
        main.post {
            observer?.let { context.applicationContext.contentResolver.unregisterContentObserver(it) }
            observer = null
            main.removeCallbacks(scan)
        }
    }

    private fun poke() {
        main.removeCallbacks(scan)
        main.postDelayed(scan, CHANGE_DELAY_MS)
    }

    /** Handles 1 SMS packet from a computer. The core lock is held, so the work moves to the worker. */
    fun onPacket(core: FluxCore, d: Device, p: Packet) {
        work(p.type) {
            val app = core.app
            if (!enabled(app)) {
                Log.i(TAG, "ignored ${p.type}: text messages are off")
                return@work
            }
            when (p.type) {
                Types.SMS_REQUEST_CONVERSATIONS -> answer(app, d, conversations(app), null, conversations = true)
                Types.SMS_REQUEST_CONVERSATION -> SmsPackets.thread(p)?.let { answer(app, d, thread(app, it), it.threadId) }
                Types.SMS_REQUEST -> SmsPackets.send(p)?.let { send(app, it) }
            }
        }
    }

    private fun work(what: String, block: () -> Unit) {
        worker.execute { runCatching(block).onFailure { Log.w(TAG, "$what failed", it) } }
    }

    /**
     * Sends the answer to a request. With [conversations], the answer is the
     * full list of conversations, and the computer replaces its list, so
     * that a conversation that the user deleted goes away.
     */
    private fun answer(context: Context, d: Device, list: List<TextMessage>, threadId: Long?, conversations: Boolean = false) {
        // The newest messages go in last, so that they stay when the watch is full.
        list.sortedBy { it.date }.forEach(changes::watch)
        SmsPackets.messagePackets(list, names(context, list), threadId, conversations = conversations).forEach { d.send(it) }
    }

    // ------------------------------------------------------------------ send

    private fun send(context: Context, req: SmsSend) {
        // fluxd refuses a longer message, but an older fluxd or another peer can still ask for one.
        if (SmsPackets.tooLong(req.body)) {
            Log.w(TAG, "not sent: the message has more than ${SmsPackets.MAX_SEND} characters")
            return
        }
        if (req.addresses.size > 1) {
            Log.w(TAG, "not sent: a message to ${req.addresses.size} addresses needs MMS")
            return
        }
        if (!granted(context, Manifest.permission.SEND_SMS)) return
        val to = req.addresses[0]
        val sm = manager(context, req.subId)
        val parts = sm.divideMessage(req.body)
        // Android writes the sent message to the SMS table, and the change watch sends it to the computers.
        if (parts.size > 1) {
            sm.sendMultipartTextMessage(to, null, parts, null, null)
        } else {
            sm.sendTextMessage(to, null, req.body, null, null)
        }
        Log.i(TAG, "sent a text message in ${parts.size} parts")
    }

    /** The SMS manager for the SIM [subId]. A SIM that is not in the phone gets the default SIM. */
    private fun manager(context: Context, subId: Int): SmsManager {
        @Suppress("DEPRECATION")
        val base = if (Build.VERSION.SDK_INT >= 31) context.getSystemService(SmsManager::class.java) else SmsManager.getDefault()
        if (subId < 0 || !activeSim(context, subId)) return base
        @Suppress("DEPRECATION")
        return if (Build.VERSION.SDK_INT >= 31) base.createForSubscriptionId(subId) else SmsManager.getSmsManagerForSubscriptionId(subId)
    }

    /** True when the SIM is in the phone. Without the phone permission, Flux cannot check, and it trusts the SIM. */
    private fun activeSim(context: Context, subId: Int): Boolean {
        val sims = context.getSystemService(SubscriptionManager::class.java) ?: return true
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) return true
        return try {
            sims.getActiveSubscriptionInfo(subId) != null
        } catch (_: SecurityException) {
            true
        }
    }

    // --------------------------------------------------------------- changes

    /** Records the newest message of each table. The first change scan sends only the messages after it. */
    private fun markNewest(context: Context) {
        lastSms = newestMark(context, Telephony.Sms.CONTENT_URI)
        lastMms = runCatching { newestMark(context, Telephony.Mms.CONTENT_URI) }.getOrDefault(Mark(0, 0))
        marked = true
    }

    private fun newestMark(context: Context, uri: Uri): Mark {
        fun newest(column: String): Long =
            context.contentResolver.query(uri, arrayOf(column), null, null, "$column DESC")?.use { c ->
                if (c.moveToFirst()) c.getLong(0) else 0L
            } ?: 0L
        return Mark(newest("_id"), newest("date"))
    }

    /** Sends the new messages and the watched messages that changed to the computers. */
    private fun pushChanges(core: FluxCore) {
        val app = core.app
        if (!enabled(app)) return
        if (!marked) {
            markNewest(app)
            return
        }
        val out = (newMessages(app) + changes.changed(watchedNow(app)))
            .distinctBy { it.mms to it.id }
            .sortedBy { it.date }
        if (out.isEmpty()) return
        out.forEach(changes::watch)
        val targets = core.connectedPaired().filter { Types.SMS_MESSAGES in it.identity.incoming }
        if (targets.isEmpty()) return
        val packets = SmsPackets.messagePackets(out, names(app, out))
        targets.forEach { d -> packets.forEach { d.send(it) } }
        Log.i(TAG, "sent ${out.size} changed messages to ${targets.size} computers")
    }

    /**
     * The messages after the marks. A new row has a higher ID or a later
     * date. The date catches a row that reuses the ID of a deleted row.
     */
    private fun newMessages(context: Context): List<TextMessage> {
        val found = ArrayList<MessageRef>()
        forEachRef(context, false, "($SMS_SHOWN) AND (_id > ? OR date > ?)", arrayOf(lastSms.id.toString(), lastSms.date.toString())) { found += it }
        val mms = runCatching {
            val list = ArrayList<MessageRef>()
            forEachRef(context, true, "($MMS_SHOWN) AND (_id > ? OR date > ?)", arrayOf(lastMms.id.toString(), lastMms.date.toString())) { list += it }
            list
        }.getOrElse {
            Log.w(TAG, "cannot read MMS", it)
            emptyList()
        }
        found += mms
        if (found.isEmpty()) return emptyList()
        found.filter { !it.mms }.let { s ->
            if (s.isNotEmpty()) lastSms = Mark(maxOf(lastSms.id, s.maxOf { it.id }), maxOf(lastSms.date, s.maxOf { it.date }))
        }
        found.filter { it.mms }.let { m ->
            if (m.isNotEmpty()) lastMms = Mark(maxOf(lastMms.id, m.maxOf { it.id }), maxOf(lastMms.date, m.maxOf { it.date } / 1000))
        }
        return load(context, found.sortedByDescending { it.date }.take(MAX_NEW))
    }

    /** The watched messages as the tables have them now. */
    private fun watchedNow(context: Context): List<TextMessage> {
        val sms = changes.ids(mms = false)
        val mms = changes.ids(mms = true)
        val out = ArrayList<TextMessage>()
        if (sms.isNotEmpty()) out += smsRows(context, "_id IN (${sms.joinToString(",")})", null, null, Int.MAX_VALUE)
        if (mms.isNotEmpty()) out += runCatching { mmsRows(context, "_id IN (${mms.joinToString(",")})", null, null, Int.MAX_VALUE) }.getOrDefault(emptyList())
        return out
    }

    // ----------------------------------------------------------------- reads

    /** The newest message of each thread, the most recent thread first. */
    private fun conversations(context: Context): List<TextMessage> {
        val newest = NewestPerThread()
        forEachRef(context, false, SMS_SHOWN, null, newest::offer)
        runCatching { forEachRef(context, true, MMS_SHOWN, null, newest::offer) }
            .onFailure { Log.w(TAG, "cannot read MMS", it) }
        return load(context, newest.result(MAX_CONVERSATIONS))
    }

    /** The newest messages of 1 thread. */
    private fun thread(context: Context, r: ThreadRequest): List<TextMessage> {
        val args = arrayOf(r.threadId.toString())
        val sms = smsRows(context, "thread_id = ? AND $SMS_SHOWN", args, "date DESC", r.count)
        val mms = runCatching {
            mmsRows(context, "thread_id = ? AND $MMS_SHOWN", args, "date DESC", r.count)
        }.getOrElse {
            Log.w(TAG, "cannot read MMS", it)
            emptyList()
        }
        return (sms + mms).sortedByDescending { it.date }.take(r.count)
    }

    /** Reads the full messages of [refs], the most recent first. */
    private fun load(context: Context, refs: List<MessageRef>): List<TextMessage> {
        val sms = refs.filter { !it.mms }.map { it.id }
        val mms = refs.filter { it.mms }.map { it.id }
        val out = ArrayList<TextMessage>()
        if (sms.isNotEmpty()) out += smsRows(context, "_id IN (${sms.joinToString(",")})", null, null, Int.MAX_VALUE)
        if (mms.isNotEmpty()) {
            out += runCatching { mmsRows(context, "_id IN (${mms.joinToString(",")})", null, null, Int.MAX_VALUE) }
                .getOrElse {
                    Log.w(TAG, "cannot read MMS", it)
                    emptyList()
                }
        }
        return out.sortedByDescending { it.date }
    }

    /** Gives the ID, thread, and date of each row to [block]. An MMS date becomes milliseconds. */
    private inline fun forEachRef(context: Context, mms: Boolean, selection: String, args: Array<String>?, block: (MessageRef) -> Unit) {
        val uri = if (mms) Telephony.Mms.CONTENT_URI else Telephony.Sms.CONTENT_URI
        context.contentResolver.query(uri, arrayOf("_id", "thread_id", "date"), selection, args, null)?.use { c ->
            while (c.moveToNext()) {
                val date = c.getLong(2)
                block(MessageRef(mms, c.getLong(0), c.getLong(1), if (mms) date * 1000 else date))
            }
        }
    }

    private fun smsRows(context: Context, selection: String, args: Array<String>?, order: String?, limit: Int): List<TextMessage> {
        val cols = arrayOf(
            Telephony.Sms._ID, Telephony.Sms.THREAD_ID, Telephony.Sms.ADDRESS, Telephony.Sms.BODY,
            Telephony.Sms.DATE, Telephony.Sms.TYPE, Telephony.Sms.READ, Telephony.Sms.SUBSCRIPTION_ID,
        )
        val out = ArrayList<TextMessage>()
        context.contentResolver.query(Telephony.Sms.CONTENT_URI, cols, selection, args, order)?.use { c ->
            while (out.size < limit && c.moveToNext()) {
                out += TextMessage(
                    id = c.getLong(0),
                    threadId = c.getLong(1),
                    body = c.getString(3).orEmpty(),
                    date = c.getLong(4),
                    type = c.getInt(5),
                    read = c.getInt(6) != 0,
                    subId = if (c.isNull(7)) -1 else c.getInt(7),
                    addresses = listOfNotNull(c.getString(2)?.trim()?.takeIf { it.isNotEmpty() }),
                )
            }
        }
        return out
    }

    private fun mmsRows(context: Context, selection: String, args: Array<String>?, order: String?, limit: Int): List<TextMessage> {
        val cols = arrayOf(
            Telephony.Mms._ID, Telephony.Mms.THREAD_ID, Telephony.Mms.DATE,
            Telephony.Mms.MESSAGE_BOX, Telephony.Mms.READ, Telephony.Mms.SUBSCRIPTION_ID,
        )
        val rows = ArrayList<TextMessage>()
        context.contentResolver.query(Telephony.Mms.CONTENT_URI, cols, selection, args, order)?.use { c ->
            while (rows.size < limit && c.moveToNext()) {
                rows += TextMessage(
                    id = c.getLong(0),
                    threadId = c.getLong(1),
                    body = "",
                    date = c.getLong(2) * 1000,
                    type = c.getInt(3),
                    read = c.getInt(4) != 0,
                    subId = if (c.isNull(5)) -1 else c.getInt(5),
                    addresses = emptyList(),
                    mms = true,
                )
            }
        }
        if (rows.isEmpty()) return rows
        val bodies = mmsBodies(context, rows.map { it.id })
        val people = participants(context, rows.map { it.threadId }.toSet())
        return rows.map { m ->
            m.copy(body = bodies[m.id].orEmpty(), addresses = mmsAddresses(context, m.id, m.type, people[m.threadId].orEmpty()))
        }
    }

    /** The text of each MMS: a label for each attachment, then the text parts. */
    private fun mmsBodies(context: Context, ids: List<Long>): Map<Long, String> {
        val parts = HashMap<Long, MutableList<String>>()
        val labels = HashMap<Long, MutableList<String>>()
        val cols = arrayOf("_id", "mid", "ct", "text", "_data")
        context.contentResolver.query("content://mms/part".toUri(), cols, "mid IN (${ids.joinToString(",")})", null, "seq")?.use { c ->
            while (c.moveToNext()) {
                val mid = c.getLong(1)
                when (val type = c.getString(2).orEmpty().lowercase()) {
                    "text/plain" -> {
                        val text = c.getString(3) ?: if (!c.isNull(4)) partText(context, c.getLong(0)) else null
                        if (!text.isNullOrBlank()) parts.getOrPut(mid) { mutableListOf() } += text
                    }
                    "application/smil" -> Unit
                    else -> labels.getOrPut(mid) { mutableListOf() } += SmsPackets.attachmentLabel(type)
                }
            }
        }
        return ids.associateWith { (labels[it].orEmpty() + parts[it].orEmpty()).joinToString("\n") }
    }

    /** The text of an MMS part that Android keeps in a file. */
    private fun partText(context: Context, partId: Long): String? = runCatching {
        context.contentResolver.openInputStream("content://mms/part/$partId".toUri())?.use { s ->
            val out = ByteArrayOutputStream()
            val buf = ByteArray(8192)
            while (out.size() < MAX_PART_BYTES) {
                val n = s.read(buf)
                if (n < 0) break
                out.write(buf, 0, n)
            }
            String(out.toByteArray(), Charsets.UTF_8)
        }
    }.getOrNull()

    /** The addresses of 1 MMS. [people] are the other people in its thread. */
    private fun mmsAddresses(context: Context, id: Long, type: Int, people: List<String>): List<String> {
        var from: String? = null
        val to = mutableListOf<String>()
        context.contentResolver.query("content://mms/$id/addr".toUri(), arrayOf("address", "type"), null, null, null)?.use { c ->
            while (c.moveToNext()) {
                val a = c.getString(0)?.trim().orEmpty()
                if (a.isEmpty() || a == MMS_SELF) continue
                when (c.getInt(1)) {
                    MMS_FROM -> from = a
                    MMS_TO, MMS_CC, MMS_BCC -> to += a
                }
            }
        }
        return SmsPackets.mmsAddresses(type, from, to, people)
    }

    /**
     * The other people in each thread, from the thread table of the phone.
     * It is empty when the phone does not share the table.
     */
    private fun participants(context: Context, threads: Set<Long>): Map<Long, List<String>> = runCatching {
        val ids = HashMap<Long, List<Long>>()
        val threadUri = "content://mms-sms/conversations?simple=true".toUri()
        context.contentResolver.query(threadUri, arrayOf("_id", "recipient_ids"), "_id IN (${threads.joinToString(",")})", null, null)?.use { c ->
            while (c.moveToNext()) ids[c.getLong(0)] = c.getString(1).orEmpty().split(' ').mapNotNull { it.toLongOrNull() }
        }
        val wanted = ids.values.flatten().toSet()
        if (wanted.isEmpty()) return@runCatching emptyMap()
        val addresses = HashMap<Long, String>()
        val canonical = "content://mms-sms/canonical-addresses".toUri()
        // This table ignores the projection, so the columns go by name.
        context.contentResolver.query(canonical, arrayOf("_id", "address"), "_id IN (${wanted.joinToString(",")})", null, null)?.use { c ->
            val id = c.getColumnIndexOrThrow("_id")
            val address = c.getColumnIndexOrThrow("address")
            while (c.moveToNext()) c.getString(address)?.trim()?.takeIf { it.isNotEmpty() }?.let { addresses[c.getLong(id)] = it }
        }
        ids.mapValues { (_, list) -> list.mapNotNull { addresses[it] } }
    }.getOrElse {
        Log.w(TAG, "cannot read the thread table", it)
        emptyMap()
    }

    /** The contact names of the addresses in [list]. It is empty without the contacts permission. */
    private fun names(context: Context, list: List<TextMessage>): Map<String, String> {
        if (!Android.hasContacts(context)) return emptyMap()
        val now = SystemClock.elapsedRealtime()
        if (nameCache.size > 2_000) nameCache.clear()
        return list.flatMap { it.addresses }.distinct().mapNotNull { a ->
            val cached = nameCache[a]?.takeIf { now - it.second < NAME_TTL_MS }
            val name = if (cached != null) cached.first else Android.contactName(context, a).also { nameCache[a] = it to now }
            name?.let { a to it }
        }.toMap()
    }

    private fun granted(context: Context, permission: String) =
        ContextCompat.checkSelfPermission(context, permission) == PackageManager.PERMISSION_GRANTED
}
