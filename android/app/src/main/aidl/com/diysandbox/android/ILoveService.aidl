package com.diysandbox.android;

import com.diysandbox.android.ILoveCallback;
import android.view.Surface;

/** Control interface for a love2d instance running in its own process. */
interface ILoveService {
    void start(in Surface surface, int width, int height, String gamePath, String bridgeArg, in ILoveCallback callback);
    void resize(int width, int height);
    void pauseGame();
    void resumeGame(in Surface surface);
    oneway void touch(int id, int action, float x, float y, float p);
    oneway void key(int keycode, boolean down);
    oneway void textInput(String text);
    void stop();
}
