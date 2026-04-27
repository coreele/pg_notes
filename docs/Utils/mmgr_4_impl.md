# Memory Impl

| **上下文类型** | AllocSetContext（默认）                    | GenerationContext                      | SlabContext                                |
| -------------- | ------------------------------------------ | -------------------------------------- | ------------------------------------------ |
| **核心特点**   | 维护多块内存<br>按大小分空闲链表，复用碎片 | 不重用单个空闲块<br>整块只有全空才释放 | 只能分配固定大小<br>无碎片、O(1) 分配/释放 |
| **适用场景**   | 通用场景                                   | FIFO; 同生命周期对象                   | 大量同尺寸对象                             |
| **实现文件**   | aset.c                                     | generation.c                           | slab.c                                     |

多态实现:

- `AllocSetContext`, `GenerationContext`, `SlabContext` 是 MemoryContext 的三种实现
- 其中 MemoryContext 类似抽象类, `palloc` 的核心是调用具体上下文实现的虚函数(虚函数表 MemoryContext::methods)
- methods 在 MemoryContext 中声明，在 `xxContextCreate` 实例化时赋值为特定上下文的函数指针，从而实现多态

```
palloc
	MemoryContext context = CurrentMemoryContext;
	ret = context->methods->alloc(context, size);
```

三种实现的基本元素:

- `Block`: 调用 `malloc` 一次获得指定大小内存空间, Block 构成双向链表
- `Chunk`: 调用 `alloc` 实际得到的内存空间

[draw_ctx_impl](assets/draw_ctx_impl.md)
