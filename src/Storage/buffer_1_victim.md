# Buffer Victim

## 读取缓存

```c
heapgettup_pagemode
	heapgetpage
		ReadBufferExtended | ReadBuffer_common
			/* 1. Local Buffers */

			/* 2. Shared Buffers */
			BufferAlloc

				/* A. Cache Hit */
				StartBufferIO*

				/* B. Cache Miss */
				GetVictimBuffer
					StrategyGetBuffer

						/* a. GetBufferFromRing */
						/* b. firstFreeBuffer */
						/* c. clock sweep(REFCOUNT >= USAGECOUNT) */
						if REFCOUNT == 0 && USAGECOUNT == 0

				BufTableInsert
				StartBufferIO*

			smgrread*
			TerminateBufferIO*

			return BufferDescriptorGetBuffer(bufHdr);

		HeapTupleSatisfiesVisibility
		scan->rs_vistuples[ntup++] = lineoff;
	lineoff = scan->rs_vistuples[lineindex];
	lpp = PageGetItemId(page, lineoff);

	/* end of scan */
	if (BufferIsValid(scan->rs_cbuf))
		ReleaseBuffer(scan->rs_cbuf);
```

## 获取缓存

- GetBufferFromRing
- StrategyControl->firstFreeBuffer
- Clock Sweep(时钟扫描算法)

```c
BufferDesc *
StrategyGetBuffer(BufferAccessStrategy strategy, uint32 *buf_state, bool *from_ring)
{
	/* a. GetBufferFromRing ... */
	/* b. firstFreeBuffer ... */

	/* c. clock sweep(REFCOUNT >= USAGECOUNT) */

	/* Nothing on the freelist, so run the "clock sweep" algorithm */
	trycounter = NBuffers;
	for (;;)
	{
		buf = GetBufferDescriptor(ClockSweepTick());

		/*
		 * If the buffer is pinned or has a nonzero usage_count, we cannot use
		 * it; decrement the usage_count (unless pinned) and keep scanning.
		 */
		local_buf_state = LockBufHdr(buf);

		if (BUF_STATE_GET_REFCOUNT(local_buf_state) == 0)
		{
			if (BUF_STATE_GET_USAGECOUNT(local_buf_state) != 0)
			{
				local_buf_state -= BUF_USAGECOUNT_ONE;

				trycounter = NBuffers;
			}
			else
			{
				/* Found a usable buffer */
				if (strategy != NULL)
					AddBufferToRing(strategy, buf);
				*buf_state = local_buf_state;
				return buf;
			}
		}
		else if (--trycounter == 0)
		{
			/*
			 * We've scanned all the buffers without making any state changes,
			 * so all the buffers are pinned (or were when we looked at them).
			 * We could hope that someone will free one eventually, but it's
			 * probably better to fail than to risk getting stuck in an
			 * infinite loop.
			 */
			UnlockBufHdr(buf, local_buf_state);
			elog(ERROR, "no unpinned buffers available");
		}
		UnlockBufHdr(buf, local_buf_state);
	}
}
```
