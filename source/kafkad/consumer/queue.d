﻿module kafkad.consumer.queue;

import kafkad.config;
import kafkad.consumer.consumer;
import kafkad.consumer.group;
import kafkad.utils.lists;
import vibe.core.sync;
import std.bitmanip;
import std.exception;
import core.memory;

// Represents single buffer of a consumer queue, 
struct QueueBuffer {
    ubyte* buffer, p;
    size_t messageSetSize;
    Exception exception;

    QueueBuffer* next;

    this(size_t size) {
        buffer = cast(ubyte*)enforce(GC.malloc(size, GC.BlkAttr.NO_SCAN));
        exception = null;
    }

    this(Exception ex) {
        exception = ex;
    }

    long findNextOffset() {
        ubyte* p = this.p;
        ubyte* end = this.p + messageSetSize;
        long offset = -2;
        while (end - p > 12) {
            offset = bigEndianToNative!long(p[0 .. 8]);
            int messageSize = bigEndianToNative!int(p[8 .. 12]);
            p += 12 + messageSize;
            if (p > end) {
                // this is last, partial message
                return offset;
            }
        }
        return offset + 1;
    }
}

// Holds the buffers for the consumer
class Queue {
    private {
        Consumer m_consumer;
        List!(QueueBuffer) m_freeBuffers, m_filledBuffers;
        QueueBuffer* m_lastBuffer;
        TaskMutex m_mutex;
        TaskCondition m_filledCondition;
        bool m_fetchPending;
        QueueGroup m_group;
        long m_offset;
    }

    // this is also updated in the fetch task
    bool fetchPending() { return m_fetchPending; }
    bool fetchPending(bool v) { return m_fetchPending = v; }

    @property auto consumer() { return m_consumer; }

    @property auto mutex() { return m_mutex; }
    @property auto filledCondition() { return m_filledCondition; }

    @property auto queueGroup() { return m_group; }
    @property auto queueGroup(QueueGroup v) { return m_group = v; }

    @property auto offset() { return m_offset; }
    @property auto offset(long v) { return m_offset = v; }

    this(Consumer consumer, in Configuration config) {
        import std.algorithm : max;
        m_consumer = consumer;
        auto m_freeBufferCount = max(2, config.consumerQueueBuffers); // at least 2
        foreach (n; 0 .. m_freeBufferCount) {
            auto qbuf = new QueueBuffer(config.consumerMaxBytes);
            m_freeBuffers.pushBack(qbuf);
        }
        m_lastBuffer = null;
        m_mutex = new TaskMutex();
        m_filledCondition = new TaskCondition(m_mutex);
        m_group = null;
    }

    bool hasFreeBuffer() {
        return !m_freeBuffers.empty;
    }

    auto getBufferToFill() {
        return m_freeBuffers.popFront();
    }

    void returnFilledBuffer(QueueBuffer* buf) {
        m_filledBuffers.pushBack(buf);
        m_filledCondition.notify();
    }

    void appendExceptionBuffer(Exception ex) {
        m_filledBuffers.pushBack(new QueueBuffer(ex));
        m_filledCondition.notify();
    }

    QueueBuffer* waitForFilledBuffer() {
        synchronized (m_mutex) {
            if (m_lastBuffer) {
                assert(!m_lastBuffer.exception);
                // return the last used buffer to the free buffer list
                m_freeBuffers.pushBack(m_lastBuffer);
                // notify the fetch task that there are buffers to be filled in
                // the fetch task will then make a batch request for all queues with free buffers
                // do not notify the task if there is a pending request for this queue (e.g. without a response yet)
                if (m_group && !m_fetchPending) {
                    synchronized (m_group.mutex) {
                        m_group.queueHasFreeBuffers(this);
                    }
                    m_fetchPending = true;
                }
            }

            while (m_filledBuffers.empty)
                m_filledCondition.wait();
            m_lastBuffer = m_filledBuffers.popFront();
            if (m_lastBuffer.exception)
                throw m_lastBuffer.exception;
            return m_lastBuffer;
        }
    }
}
