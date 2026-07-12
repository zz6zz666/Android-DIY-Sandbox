package com.diysandbox.android;

/** Reverse callback from the love service process back to the main process. */
oneway interface ILoveCallback {
    void requestRecordAudioPermission();
}
