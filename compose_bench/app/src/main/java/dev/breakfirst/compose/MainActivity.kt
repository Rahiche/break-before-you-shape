package dev.breakfirst.compose

import android.app.Activity
import android.content.Context
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.createFontFamilyResolver
import androidx.compose.ui.text.style.LineBreak
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.LayoutDirection
import androidx.compose.ui.unit.sp
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Runs the job in files/job.json and writes files/out.json: Compose's own widths
 * and line breaks, from TextMeasurer, which lays text out as the Text composable
 * does. The host side is tool/compose_check.dart.
 */
class MainActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val dir = getExternalFilesDir(null)!!
        Thread {
            val out = try {
                Harness(this).run(JSONObject(File(dir, "job.json").readText()))
            } catch (e: Throwable) {
                JSONObject().put("error", Log.getStackTraceString(e))
            }
            val tmp = File(dir, "out.json.tmp")
            tmp.writeText(out.toString())
            tmp.renameTo(File(dir, "out.json"))
            Log.i("BF", "BFDONE")
            finish()
        }.start()
    }
}

class Harness(context: Context) {
    // Density 1: sp and dp are px, so sizes and widths are the host's numbers.
    private val measurer = TextMeasurer(
        createFontFamilyResolver(context), Density(1f, 1f), LayoutDirection.Ltr, cacheSize = 0,
    )
    private val roboto = FontFamily(Font("Roboto-Regular.ttf", context.assets))

    fun run(job: JSONObject): JSONObject = when (val kind = job.getString("kind")) {
        "info" -> info()
        "measure" -> measure(job)
        "layout" -> layout(job)
        "time" -> time(job)
        else -> error("unknown job $kind")
    }

    /** The Text composable's style: a font family and a size, Compose's defaults for the rest. */
    private fun style(job: JSONObject): TextStyle {
        var s = TextStyle(fontFamily = roboto, fontSize = job.getDouble("fontSize").sp)
        when (job.optString("lineBreak")) {
            "simple" -> s = s.copy(lineBreak = LineBreak.Simple)
            "paragraph" -> s = s.copy(lineBreak = LineBreak.Paragraph)
            "heading" -> s = s.copy(lineBreak = LineBreak.Heading)
        }
        if (job.has("letterSpacing")) s = s.copy(letterSpacing = job.getDouble("letterSpacing").sp)
        return s
    }

    private fun info(): JSONObject = JSONObject()
        .put("sdk", Build.VERSION.SDK_INT)
        .put("release", Build.VERSION.RELEASE)
        .put("device", Build.MODEL)
        .put("defaultLineBreak", TextStyle.Default.lineBreak.toString())
        .put("defaultHyphens", TextStyle.Default.hyphens.toString())
        .put("defaultPlatformStyle", TextStyle.Default.platformStyle.toString())

    /** Widths of one-line strings: the x position after the last character, or every position with "prefix". */
    private fun measure(job: JSONObject): JSONObject {
        val style = style(job)
        val strings = job.getJSONArray("strings")
        val prefix = job.optBoolean("prefix")
        val widths = JSONArray()
        for (i in 0 until strings.length()) {
            val s = strings.getString(i)
            val r = measurer.measure(AnnotatedString(s), style, softWrap = false, maxLines = 1)
            if (prefix) {
                val xs = JSONArray()
                for (k in 0..s.length) xs.put(r.getHorizontalPosition(k, true).toDouble())
                widths.put(xs)
            } else {
                widths.put(r.getHorizontalPosition(s.length, true).toDouble())
            }
        }
        return JSONObject().put("widths", widths)
    }

    /** For each width (px) and text: line count, height (px, and Compose's rounded size), and line starts. */
    private fun layout(job: JSONObject): JSONObject {
        val style = style(job)
        val texts = job.getJSONArray("texts")
        val widths = job.getJSONArray("widths")
        val out = JSONArray()
        for (w in 0 until widths.length()) {
            val c = Constraints(maxWidth = widths.getInt(w))
            val per = JSONArray()
            for (i in 0 until texts.length()) {
                val r = measurer.measure(AnnotatedString(texts.getString(i)), style, constraints = c)
                val starts = JSONArray()
                for (l in 1 until r.lineCount) starts.put(r.getLineStart(l))
                per.put(
                    JSONArray().put(r.lineCount).put(r.multiParagraph.height.toDouble()).put(r.size.height).put(starts),
                )
            }
            out.put(per)
        }
        return JSONObject().put("layouts", out)
    }

    /** Median ms to measure every text at one width, over "reps" runs. */
    private fun time(job: JSONObject): JSONObject {
        val style = style(job)
        val texts = job.getJSONArray("texts")
        val list = (0 until texts.length()).map { AnnotatedString(texts.getString(it)) }
        val c = Constraints(maxWidth = job.getInt("width"))
        val ms = mutableListOf<Double>()
        var sink = 0
        repeat(job.optInt("reps", 5)) {
            val t0 = SystemClock.elapsedRealtimeNanos()
            for (s in list) sink += measurer.measure(s, style, constraints = c).size.height
            ms.add((SystemClock.elapsedRealtimeNanos() - t0) / 1e6)
        }
        return JSONObject().put("ms", JSONArray(ms)).put("medianMs", ms.sorted()[ms.size / 2]).put("sink", sink)
    }
}
