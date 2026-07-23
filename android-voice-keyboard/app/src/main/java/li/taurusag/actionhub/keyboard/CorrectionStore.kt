package li.taurusag.actionhub.keyboard

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper

class CorrectionStore(context: Context) : SQLiteOpenHelper(context, "corrections.db", null, 1) {
    override fun onCreate(database: SQLiteDatabase) {
        database.execSQL(
            "CREATE TABLE corrections (" +
                "id INTEGER PRIMARY KEY AUTOINCREMENT, " +
                "heard TEXT NOT NULL, " +
                "replacement TEXT NOT NULL, " +
                "use_count INTEGER NOT NULL DEFAULT 0, " +
                "last_used_at INTEGER NOT NULL, " +
                "UNIQUE(heard, replacement))",
        )
        database.execSQL("CREATE INDEX corrections_heard ON corrections(heard)")
    }

    override fun onUpgrade(database: SQLiteDatabase, oldVersion: Int, newVersion: Int) {}

    fun suggestionsFor(heard: String): List<String> =
        readableDatabase.rawQuery(
            "SELECT replacement FROM corrections WHERE heard = ? ORDER BY use_count DESC, last_used_at DESC LIMIT 8",
            arrayOf(heard),
        ).use { cursor ->
            val replacements = mutableListOf<String>()
            while (cursor.moveToNext()) replacements.add(cursor.getString(0))
            replacements
        }

    fun recordCorrection(heard: String, replacement: String) {
        val now = System.currentTimeMillis()
        val row = ContentValues()
        row.put("heard", heard)
        row.put("replacement", replacement)
        row.put("use_count", 0)
        row.put("last_used_at", now)
        writableDatabase.insertWithOnConflict("corrections", null, row, SQLiteDatabase.CONFLICT_IGNORE)
        writableDatabase.execSQL(
            "UPDATE corrections SET use_count = use_count + 1, last_used_at = ? WHERE heard = ? AND replacement = ?",
            arrayOf(now, heard, replacement),
        )
    }
}
